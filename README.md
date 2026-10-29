# argparse.cr

A Crystal port of Python's [`argparse`](https://docs.python.org/3/library/argparse.html).

The parser follows CPython's algorithm rather than reinventing one: argv is
classified into a pattern of option (`O`) and argument (`A`) characters and
`nargs` values are matched against that pattern, so edge cases such as `-x-1`,
`-3.5`, abbreviated long options, `--`, and interleaved positionals behave the
way they do in Python.  Usage and help messages are laid out the same way too,
including line wrapping.

## Usage

```crystal
require "argparse"

parser = Argparse::ArgumentParser.new(prog: "demo", description: "Demo program")
parser.add_argument("-v", "--verbose", action: "count", help: "increase verbosity")
parser.add_argument("--pair", nargs: 2, type: "int", help: "two integers")
parser.add_argument("--tag", action: "append", nargs: "+", help: "add tags")
parser.add_argument("--no-color", action: "store_false", dest: "color", default: true)
parser.add_argument("files", nargs: "*", help: "input files")

options = parser.parse_args
options.int("verbose")    # => 2 for `-vv`
options.array("pair")     # => [1_i64, 2_i64]
options["tag"]            # => [["a", "b"], ["c", "d"]]
options.array("files")    # => ["x"]
```

`parser.parse_args(ARGV)` is the explicit form; `ARGV` is the default.  Use
`argv = ARGV` when you also want `parse_known_args`, which returns the namespace
and the arguments that were not recognised:

```crystal
options, extras = parser.parse_known_args(["--unknown", "file.txt"])
```

The public API mirrors Python where Crystal allows it:

* `ArgumentParser.new(prog:, usage:, description:, epilog:, add_help:,
  prefix_chars:, allow_abbrev:, argument_default:, exit_on_error:)`, plus a
  `width:` extension that controls help wrapping (default `78`, the terminal
  width Python uses).
* `add_argument(*names, action:, nargs:, const:, default:, type:, choices:,
  required:, help:, metavar:, dest:, version:)`.  `action` accepts `store`,
  `store_const`, `store_true`, `store_false`, `append`, `append_const`, `extend`,
  `count`, `help`, `version` and `boolean_optional`.
* `add_mutually_exclusive_group(required:)`, `set_defaults(**defaults)`,
  `get_default(dest)`, `format_usage`, `format_help`, `print_usage`,
  `print_help`, `error(message)`.
* `Argparse::SUPPRESS` as a `default:` or `help:` value.
* A block instead of `type:` supplies a custom converter:
  `parser.add_argument("--path") { |value| Path[value].as(Argparse::Value) }`.

Values are stored in an `Argparse::Namespace` which offers `[]`, `[]?`,
`has_key?`, `to_h` and typed readers (`string`, `int`, `float`, `bool`, `array`).

## Conformance with CPython

The spec suite is generated from CPython's own `Lib/test/test_argparse.py`, so
the expectations are Python's, not hand-written approximations:

```console
$ crystal spec
883 examples, 0 failures
```

* `spec/fixtures/cpython_test_argparse.json` holds the data driven
  `ParserTestCase` classes this port supports (89 classes, 388 accepted command
  lines with their expected namespace, 328 rejected command lines).
* `spec/fixtures/cpython_help_cases.json` holds the `HelpTestCase` classes that
  use features this port supports, with the exact usage and help text CPython
  prints for them (24 classes).

Regenerate both fixtures (the script downloads the pinned CPython tag, or pass
`--source` for a local copy):

```console
$ python3 spec/support/extract_python_cases.py \
    --output spec/fixtures/cpython_test_argparse.json \
    --help-output spec/fixtures/cpython_help_cases.json
```

Error messages, exit statuses, `parse_known_args` behaviour, `--` handling,
namespace defaults and mutually exclusive groups are additionally covered by
`spec/argparse_spec.cr` (30 examples), ported by hand from the upstream unit
tests.

### Not implemented

These upstream feature groups are skipped by the extractor and have no
equivalent here:

* `add_subparsers` and parser inheritance via `parents=`.
* Named argument groups (`add_argument_group`) and their help layout.
* `fromfile_prefix_chars` argument files, `FileType`/`type=open`, and
  `parse_intermixed_args`.
* Custom `Action` subclasses, arbitrary `type` callables other than through a
  block, tuple `metavar`s, formatter classes, `deprecated=` options, message
  translations, and `suggest_on_error:` "did you mean" hints.
* `argparse.SUPPRESS` for `dest`/`nargs`.

Integer values are `Int64`; Python's arbitrary precision integers overflow
instead of widening.
