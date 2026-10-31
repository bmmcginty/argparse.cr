# argparse.cr

A Crystal port of Python's [`argparse`](https://docs.python.org/3/library/argparse.html).

The parser follows CPython's algorithm rather than reinventing one: argv is
classified into a pattern of option (`O`) and argument (`A`) characters and
`nargs` values are matched against that pattern, so edge cases such as `-x-1`,
`-3.5`, abbreviated long options, `--`, and interleaved positionals behave the
way they do in Python.  Usage and help messages are laid out the same way too,
including line wrapping.

## Installation

Add the shard to your project's `shard.yml`:

```yaml
dependencies:
  argparse:
    github: bmmcginty/argparse
```

Then install dependencies and require the library:

```console
$ shards install
```

```crystal
require "argparse"
```

The library source is `src/argparse.cr`, so `require "argparse"` resolves
normally once the shard is installed.

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

Subcommands, argument groups, inherited parsers, and intermixed positionals are
also supported:

```crystal
parser = Argparse::ArgumentParser.new(prog: "demo")
subparsers = parser.add_subparsers(dest: "command", required: true)

serve = subparsers.add_parser("serve", help: "start the server")
serve.add_argument("--port", type: "int", default: 8080_i64)
serve.add_argument("files", nargs: "*")

options = parser.parse_args(["serve", "a.txt", "--port", "9000"])
```

The public API mirrors Python where Crystal allows it:

* `ArgumentParser.new(prog:, usage:, description:, epilog:, parents:,
  formatter_class:, prefix_chars:, fromfile_prefix_chars:, argument_default:,
  conflict_handler:, add_help:, allow_abbrev:, exit_on_error:,
  suggest_on_error:)`, plus a `width:` extension that controls help wrapping
  (default `78`, the terminal width Python uses).
* `add_argument(*names, action:, nargs:, const:, default:, type:, choices:,
  required:, help:, metavar:, dest:, version:, deprecated:)`.  `action` accepts
  the built-in names (`store`, `store_const`, `store_true`, `store_false`,
  `append`, `append_const`, `extend`, `count`, `help`, `version`,
  `boolean_optional`), `Argparse::BooleanOptionalAction`, or a custom
  `Argparse::Action` instance/class.
* `nargs:` accepts an integer, `?`, `*`, `+`, `...`, `A...`, the matching
  constants (`Argparse::OPTIONAL`, `Argparse::ZERO_OR_MORE`,
  `Argparse::ONE_OR_MORE`, `Argparse::PARSER`, `Argparse::REMAINDER`), or
  `Argparse::SUPPRESS`.
* `metavar:` accepts a string or an array of strings for tuple-style nargs.
* `type:` accepts `"int"`, `"float"`, `"complex"`, `"str"`, a `Proc(String,
  Value)`, or an `Argparse::FileType`.  A block instead of `type:` supplies a
  custom converter; converters may raise `Argparse::ArgumentTypeError` to
  choose the error message.
* `add_argument_group(title:, description:)`,
  `add_mutually_exclusive_group(required:)`, `add_subparsers(...)`,
  `SubparsersAction#add_parser(name, aliases:, help:, deprecated:, ...)`,
  `set_defaults(**defaults)`, and `get_default(dest)`.
* `parse_args(args, namespace)`, `parse_known_args(args, namespace)`,
  `parse_intermixed_args`, and `parse_known_intermixed_args`.
* `fromfile_prefix_chars:` argument files, with an overridable
  `convert_arg_line_to_args(line)` hook.
* `conflict_handler: "error" | "resolve"` and `parents: [parser, ...]`.
* `formatter_class:` with `Argparse::HelpFormatter`,
  `Argparse::RawDescriptionHelpFormatter`, `Argparse::RawTextHelpFormatter`,
  `Argparse::ArgumentDefaultsHelpFormatter`, and
  `Argparse::MetavarTypeHelpFormatter`, or a `Proc(String, HelpFormatter)`
  factory.  Custom formatters may override `fill_text`, `split_lines`,
  `help_string`, and the default metavar methods.
* `Argparse::SUPPRESS` as a `default:`, `help:`, `dest:`, or `nargs:` value.
* `register_action(name, action)` / `register("action", name, action)` for
  name-based custom actions.
* `format_usage`, `format_help`, `print_usage`, `print_help`, `error(message)`,
  `warning(message)`, `print_message(message, io)`, and
  `exit(status, message)`.
* `Argparse.translator = ->(message : String) { ... }` for gettext-style
  message translation.

Values are stored in an `Argparse::Namespace` which offers `[]`, `[]?`,
`has_key?`, `to_h` and typed readers (`string`, `int`, `float`, `bool`, `array`).

## Conformance with CPython

The spec suite is generated from CPython's own `Lib/test/test_argparse.py`, so
the expectations are Python's, not hand-written approximations:

```console
$ crystal spec
1001 examples, 0 failures
```

* `spec/fixtures/cpython_test_argparse.json` holds the data driven
  `ParserTestCase` classes this port supports (91 classes, 405 accepted command
  lines with their expected namespace, 340 rejected command lines).
* `spec/fixtures/cpython_help_cases.json` holds the `HelpTestCase` classes that
  use features this port supports, with the exact usage and help text CPython
  prints for them (39 classes), including named groups, formatter classes,
  subparsers, and tuple metavars.

Regenerate both fixtures (the script downloads the pinned CPython tag, or pass
`--source` for a local copy):

```console
$ python3 spec/support/extract_python_cases.py \
    --output spec/fixtures/cpython_test_argparse.json \
    --help-output spec/fixtures/cpython_help_cases.json
```

Error messages, exit statuses, `parse_known_args` behaviour, `--` handling,
namespace defaults, mutually exclusive groups, argument files, intermixed
parsing, formatters, custom actions, deprecation warnings, and suggestions are
additionally covered by hand-written specs in `spec/argparse_spec.cr` and
`spec/feature_parity_spec.cr`.  `spec/usage_guide_spec.cr` is a short,
feature-by-feature usage guide for the same API.

### Not implemented

These limits are language- or runtime-specific rather than missing parser
features:

* Python `Action` subclasses cannot be imported into Crystal.  Use an
  `Argparse::Action` subclass/instance, a block converter, or
  `register_action` instead.
* Python objects and arbitrary Python callables cannot be used from Crystal;
  `Proc`, `FileType`, and `Action` are the Crystal equivalents.
* Message translation uses `Argparse.translator` rather than Python gettext
  catalogs.
* Colorized help/error output (`color=`) is not emitted.
* `FileType` returns a Crystal `IO`; `bufsize`, `encoding`, and `errors` are
  accepted for API compatibility but are not applied by Crystal's file API.
* Integer values are `Int64`; Python's arbitrary precision integers overflow
  instead of widening.
