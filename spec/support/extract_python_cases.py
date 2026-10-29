#!/usr/bin/env python3
"""Extract the data driven test cases from CPython's test_argparse.py.

The upstream test suite describes parsers declaratively: each
``ParserTestCase`` subclass lists its argument signatures, the argv strings
that must be accepted together with the namespace they produce, and the argv
strings that must be rejected.  That description is language independent, so
this script dumps it to JSON where the Crystal spec suite can consume it.

Usage:
    python3 spec/support/extract_python_cases.py \
        [--source path/to/test_argparse.py] [--output spec/fixtures/...]

Without ``--source`` the file is downloaded from the pinned CPython tag.
"""

import argparse
import json
import sys
import types
import urllib.request

CPYTHON_TAG = "v3.14.0"
SOURCE_URL = f"https://raw.githubusercontent.com/python/cpython/{CPYTHON_TAG}/Lib/test/test_argparse.py"

# Parser/test helpers that are fine to ignore for the extraction.
STUBBED_MODULES = [
    "test",
    "test.support",
    "test.support.os_helper",
    "test.support.i18n_helper",
]


def install_stubs():
    """Provide the few test.* helpers test_argparse imports."""
    import contextlib

    test = types.ModuleType("test")
    support = types.ModuleType("test.support")
    os_helper = types.ModuleType("test.support.os_helper")
    i18n_helper = types.ModuleType("test.support.i18n_helper")

    @contextlib.contextmanager
    def captured_stderr():
        yield

    def passthrough_decorator(*args, **kwargs):
        if len(args) == 1 and callable(args[0]) and not kwargs:
            return args[0]
        return lambda function: function

    support.captured_stderr = captured_stderr
    support.force_not_colorized = lambda function: function
    support.force_not_colorized_test_class = lambda cls: cls
    support.os_helper = os_helper
    os_helper.TESTFN = "test_argparse.tmp"
    os_helper.unlink = lambda *a, **k: None
    os_helper.temp_dir = lambda *a, **k: contextlib.nullcontext("/tmp")
    os_helper.temp_cwd = lambda *a, **k: contextlib.nullcontext(".")
    os_helper.FS_NONASCII = "\u00e9"
    os_helper.TESTFN_UNDECODABLE = b"@undecodable-name"
    os_helper.TESTFN_NONASCII = "nonascii-name"
    # Any remaining helper attribute is used as a test decorator; a no-op
    # decorator keeps module level decoration working.
    os_helper.__getattr__ = lambda name: passthrough_decorator
    support.__getattr__ = lambda name: passthrough_decorator

    class TestTranslationsBase:
        pass

    i18n_helper.TestTranslationsBase = TestTranslationsBase
    i18n_helper.update_translation_snapshots = lambda *a, **k: None

    test.support = support
    sys.modules["test"] = test
    sys.modules["test.support"] = support
    sys.modules["test.support.os_helper"] = os_helper
    sys.modules["test.support.i18n_helper"] = i18n_helper


# Values that survive a JSON round trip and that a Crystal parser can produce.
def encode_value(value):
    """Encode a python value, or raise Unsupported when it cannot be encoded."""
    if value is argparse.SUPPRESS:
        return {"__suppress__": True}
    if value is None or isinstance(value, (bool, str)):
        return value
    if isinstance(value, int):
        if -(2**63) <= value < 2**63:
            return value
        raise Unsupported(f"integer out of int64 range: {value}")
    if isinstance(value, float):
        return value
    if isinstance(value, (list, tuple)):
        return [encode_value(item) for item in value]
    # Anything else (a class object, for instance) cannot be represented in
    # Crystal; a marker keeps "the value is passed through unchanged"
    # checkable without pretending to model arbitrary Python objects.
    return f"<pyobject {type(value).__name__}>"


class Unsupported(Exception):
    pass


def encode_kwargs(kwargs, argument_kwargs):
    """Encode add_argument/parser keyword arguments."""
    encoded = {}
    for key, value in kwargs.items():
        if key == "action":
            encoded[key] = encode_action(argument_kwargs, value)
        elif key == "type":
            encoded[key] = encode_type(argument_kwargs, value)
        elif key == "choices":
            encoded[key] = [encode_choice(item, argument_kwargs) for item in value]
        elif key in ("const", "default"):
            encoded[key] = encode_value(value)
        elif key in ("nargs", "dest", "required", "help", "version"):
            encoded[key] = encode_value(value)
        elif key == "metavar":
            if not isinstance(value, str):
                raise Unsupported(f"metavar {value!r}")
            encoded[key] = value
        else:
            raise Unsupported(f"argument keyword {key!r}")
    return encoded


BUILTIN_ACTIONS = {
    "store": "store",
    "extend": "extend",
    "store_const": "store_const",
    "store_true": "store_true",
    "store_false": "store_false",
    "append": "append",
    "append_const": "append_const",
    "count": "count",
    "help": "help",
    "version": "version",
}


def encode_action(argument_kwargs, value):
    if value is None:
        return "store"
    if isinstance(value, str):
        if value in BUILTIN_ACTIONS:
            return value
        raise Unsupported(f"action {value!r}")
    action_class = value if isinstance(value, type) else type(value)
    name = action_class.__name__
    if name == "BooleanOptionalAction":
        return "boolean_optional"
    raise Unsupported(f"custom action {name}")


BUILTIN_TYPES = {int: "int", float: "float", str: "str"}


def encode_type(argument_kwargs, value):
    if value is None:
        return None
    if value in BUILTIN_TYPES:
        return BUILTIN_TYPES[value]
    raise Unsupported(f"type {getattr(value, '__name__', value)!r}")


def encode_choice(value, argument_kwargs):
    if isinstance(value, (str, int, float)) and not isinstance(value, bool):
        return value
    raise Unsupported(f"choice {value!r}")


def signature_payload(sig):
    args = [str(item) for item in sig.args]
    kwargs = encode_kwargs(sig.kwargs, None)
    return {"args": args, "kwargs": kwargs}


def parser_payload(sig):
    encoded = {}
    for key, value in sig.kwargs.items():
        if key in ("prog", "usage", "description", "epilog"):
            encoded[key] = encode_value(value)
        elif key in ("add_help", "allow_abbrev", "exit_on_error"):
            encoded[key] = encode_value(value)
        elif key == "prefix_chars":
            encoded[key] = encode_value(value)
        elif key == "argument_default":
            encoded[key] = encode_value(value)
        else:
            raise Unsupported(f"parser keyword {key!r}")
    if sig.args:
        raise Unsupported("positional parser arguments")
    return encoded


def split_argv(args):
    if isinstance(args, str):
        return args.split()
    return [str(item) for item in args]


def namespace_payload(ns):
    return {key: encode_value(value) for key, value in sorted(vars(ns).items())}


def extract(module):
    parser_test_case = module.ParserTestCase
    cases = []
    for name in sorted(dir(module)):
        cls = getattr(module, name)
        if not isinstance(cls, type) or not issubclass(cls, parser_test_case):
            continue
        if cls is parser_test_case:
            continue
        record = {
            "name": name,
            "documentation": (cls.__doc__ or "").strip(),
            "skip": None,
            "parser": {},
            "arguments": [],
            "failures": [],
            "successes": [],
        }
        try:
            record["parser"] = parser_payload(cls.parser_signature)
            if cls.parser_class is not module.ErrorRaisingArgumentParser:
                raise Unsupported(f"parser_class {cls.parser_class.__name__}")
            record["arguments"] = [
                signature_payload(sig) for sig in cls.argument_signatures
            ]
            for args in cls.failures:
                record["failures"].append(split_argv(args))
            for args, expected in cls.successes:
                if not isinstance(expected, module.NS):
                    raise Unsupported(f"expected namespace {type(expected).__name__}")
                record["successes"].append(
                    {"argv": split_argv(args), "namespace": namespace_payload(expected)}
                )
        except Unsupported as error:
            record["skip"] = str(error)
            record["arguments"] = []
            record["failures"] = []
            record["successes"] = []
        cases.append(record)
    return cases


def extract_help_cases(module):
    """Extract the expected usage/help text of every HelpTestCase subclass."""
    import argparse as argparse_module
    import os
    import textwrap

    help_test_case = module.HelpTestCase
    cases = []
    for name in sorted(dir(module)):
        cls = getattr(module, name)
        if not isinstance(cls, type) or not issubclass(cls, help_test_case):
            continue
        if cls is help_test_case:
            continue
        record = {
            "name": name,
            "documentation": (cls.__doc__ or "").strip(),
            "skip": None,
            "parser": {},
            "arguments": [],
            "width": None,
            "usage": textwrap.dedent(getattr(cls, "usage", "")),
            "help": textwrap.dedent(getattr(cls, "help", "")),
        }
        try:
            if getattr(cls, "argument_group_signatures", []):
                raise Unsupported("argument groups")
            if getattr(cls, "subparsers_signatures", []):
                raise Unsupported("subparsers")
            record["parser"] = parser_payload(cls.parser_signature)
            record["arguments"] = [
                signature_payload(sig) for sig in cls.argument_signatures
            ]
            record["width"] = detect_width(cls, module, argparse_module, os)
        except Unsupported as error:
            record["skip"] = str(error)
        cases.append(record)
    return cases


def build_python_parser(cls, module, argparse_module, os):
    os.environ["COLUMNS"] = "80"
    kwargs = dict(cls.parser_signature.kwargs)
    parser = argparse_module.ArgumentParser(*cls.parser_signature.args, **kwargs)
    for sig in cls.argument_signatures:
        parser.add_argument(*sig.args, **sig.kwargs)
    return parser


def render_with_width(parser, formatter_width, kind):
    """Render usage/help with a specific formatter width."""
    original = parser._get_formatter

    def make_formatter():
        formatter = original()
        formatter._width = formatter_width
        formatter._max_help_position = min(24, max(formatter_width - 20, 4))
        return formatter

    parser._get_formatter = make_formatter
    try:
        return parser.format_usage() if kind == "usage" else parser.format_help()
    finally:
        del parser._get_formatter


def detect_width(cls, module, argparse_module, os):
    """Find the formatter width that reproduces the recorded expectation.

    ``Unsupported`` is raised when the installed argparse cannot reproduce the
    recorded text, which means the case does not apply to this Python version.
    """
    import textwrap

    expected_usage = textwrap.dedent(cls.usage)
    expected_help = textwrap.dedent(cls.help)
    parser = build_python_parser(cls, module, argparse_module, os)
    for columns in range(10, 130):
        formatter_width = max(columns - 2, 11)
        if (render_with_width(parser, formatter_width, "usage") == expected_usage and
                render_with_width(parser, formatter_width, "help") == expected_help):
            return formatter_width
    raise Unsupported("expectation does not match installed argparse")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", help="local copy of test_argparse.py")
    parser.add_argument("--output", required=True)
    parser.add_argument("--help-output", help="also dump help/usage cases")
    options = parser.parse_args()

    if options.source:
        with open(options.source, "r", encoding="utf-8") as handle:
            source = handle.read()
    else:
        with urllib.request.urlopen(SOURCE_URL) as response:
            source = response.read().decode("utf-8")

    install_stubs()
    module = types.ModuleType("cpython_test_argparse")
    module.__file__ = options.source or SOURCE_URL
    sys.modules[module.__name__] = module
    exec(compile(source, module.__file__, "exec"), module.__dict__)

    payload = {
        "source": SOURCE_URL,
        "extracted_with": f"Python {sys.version.split()[0]}",
        "cases": extract(module),
    }
    with open(options.output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")

    if options.help_output:
        help_payload = {
            "source": SOURCE_URL,
            "extracted_with": f"Python {sys.version.split()[0]}",
            "cases": extract_help_cases(module),
        }
        with open(options.help_output, "w", encoding="utf-8") as handle:
            json.dump(help_payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        help_supported = [case for case in help_payload["cases"] if not case["skip"]]
        help_skipped = [case for case in help_payload["cases"] if case["skip"]]
        print(f"help cases: {len(help_supported)} supported, "
              f"{len(help_skipped)} skipped", file=sys.stderr)
        for case in help_skipped:
            print(f"  skipped {case['name']}: {case['skip']}", file=sys.stderr)

    supported = [case for case in payload["cases"] if not case["skip"]]
    skipped = [case for case in payload["cases"] if case["skip"]]
    successes = sum(len(case["successes"]) for case in supported)
    failures = sum(len(case["failures"]) for case in supported)
    print(f"cases: {len(supported)} supported, {len(skipped)} skipped", file=sys.stderr)
    print(f"successes: {successes}, failures: {failures}", file=sys.stderr)
    for case in skipped:
        print(f"  skipped {case['name']}: {case['skip']}", file=sys.stderr)


if __name__ == "__main__":
    main()
