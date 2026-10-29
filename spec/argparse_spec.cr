require "./spec_helper"

# Hand ported cases from CPython's `Lib/test/test_argparse.py` that are written
# as ordinary unit tests upstream (error message content, `parse_known_args`
# behaviour, `--` handling, namespaces, mutually exclusive groups, ...).
#
# The expected strings are the ones CPython produces; they were compared against
# `CPython 3.14` while porting.

# A parser that records what CPython would write to stderr and raises instead of
# terminating the process, mirroring `ErrorRaisingArgumentParser`.
private class RecordingParser < Argparse::ArgumentParser
  class Exited < Exception
  end

  getter stderr_text = ""
  getter exit_status : Int32? = nil

  def error(message : String) : NoReturn
    @stderr_text = "#{format_usage}#{prog}: error: #{message}\n"
    @exit_status = 2
    raise Exited.new
  end
end

private def recording_parser(prog : String = "PROG") : RecordingParser
  RecordingParser.new(prog: prog)
end

private def stderr_for(parser : RecordingParser, argv : Array(String)) : String
  expect_raises(RecordingParser::Exited) { parser.parse_args(argv) }
  parser.stderr_text
end

private def namespace(**pairs) : Argparse::Namespace
  values = Hash(String, Argparse::Value).new
  pairs.each { |key, value| values[key.to_s] = value }
  Argparse::Namespace.new(values)
end

describe "error messages" do
  it "reports missing required positionals and options" do
    parser = recording_parser
    parser.add_argument("foo")
    stderr_for(parser, [] of String).should eq(
      "usage: PROG [-h] foo\n" \
      "PROG: error: the following arguments are required: foo\n")

    parser = recording_parser
    parser.add_argument("--req", required: true)
    stderr_for(parser, [] of String).should eq(
      "usage: PROG [-h] --req REQ\n" \
      "PROG: error: the following arguments are required: --req\n")
  end

  it "reports a missing option value" do
    parser = recording_parser
    parser.add_argument("-x", "--xxx")
    stderr_for(parser, ["-x"]).should eq(
      "usage: PROG [-h] [-x XXX]\n" \
      "PROG: error: argument -x/--xxx: expected one argument\n")
  end

  it "reports the number of arguments an option expected" do
    parser = recording_parser
    parser.add_argument("-x", nargs: 2)
    stderr_for(parser, ["-x", "a"]).should eq(
      "usage: PROG [-h] [-x X X]\n" \
      "PROG: error: argument -x: expected 2 arguments\n")

    parser = recording_parser
    parser.add_argument("-x", nargs: 1)
    stderr_for(parser, ["-x"]).should eq(
      "usage: PROG [-h] [-x X]\n" \
      "PROG: error: argument -x: expected 1 argument\n")
  end

  it "reports a missing argument for nargs='+'" do
    parser = recording_parser
    parser.add_argument("-x", nargs: "+")
    stderr_for(parser, ["-x"]).should eq(
      "usage: PROG [-h] [-x X [X ...]]\n" \
      "PROG: error: argument -x: expected at least one argument\n")
  end

  it "reports unrecognized arguments" do
    parser = recording_parser
    parser.add_argument("--foo")
    stderr_for(parser, ["--bar"]).should eq(
      "usage: PROG [-h] [--foo FOO]\n" \
      "PROG: error: unrecognized arguments: --bar\n")

    parser = recording_parser
    parser.add_argument("foo")
    stderr_for(parser, ["a", "b"]).should eq(
      "usage: PROG [-h] foo\n" \
      "PROG: error: unrecognized arguments: b\n")
  end

  it "reports invalid choices after conversion" do
    parser = recording_parser
    parser.add_argument("--foo", choices: ["a", "b"])
    stderr_for(parser, ["--foo", "x"]).should eq(
      "usage: PROG [-h] [--foo {a,b}]\n" \
      "PROG: error: argument --foo: invalid choice: 'x' (choose from 'a', 'b')\n")

    parser = recording_parser
    parser.add_argument("spam", type: "int", choices: [1_i64, 2_i64, 3_i64])
    stderr_for(parser, ["9"]).should eq(
      "usage: PROG [-h] {1,2,3}\n" \
      "PROG: error: argument spam: invalid choice: '9' (choose from '1', '2', '3')\n")
  end

  it "reports invalid type conversions" do
    parser = recording_parser
    parser.add_argument("--foo", type: "int")
    stderr_for(parser, ["--foo", "a"]).should eq(
      "usage: PROG [-h] [--foo FOO]\n" \
      "PROG: error: argument --foo: invalid int value: 'a'\n")

    parser = recording_parser
    parser.add_argument("--f", type: "float")
    stderr_for(parser, ["--f", "x"]).should eq(
      "usage: PROG [-h] [--f F]\n" \
      "PROG: error: argument --f: invalid float value: 'x'\n")
  end

  it "reports ambiguous option abbreviations" do
    parser = recording_parser
    parser.add_argument("--foo")
    parser.add_argument("--fob")
    stderr_for(parser, ["--fo", "x"]).should eq(
      "usage: PROG [-h] [--foo FOO] [--fob FOB]\n" \
      "PROG: error: ambiguous option: --fo could match --foo, --fob\n")
  end

  it "reports an ignored explicit argument" do
    parser = recording_parser
    parser.add_argument("-x", action: "store_true")
    stderr_for(parser, ["-x=y"]).should eq(
      "usage: PROG [-h] [-x]\n" \
      "PROG: error: argument -x: ignored explicit argument 'y'\n")
  end

  it "reports mutually exclusive conflicts" do
    parser = recording_parser
    group = parser.add_mutually_exclusive_group
    group.add_argument("--foo", action: "store_true")
    group.add_argument("--bar", action: "store_true")
    stderr_for(parser, ["--foo", "--bar"]).should eq(
      "usage: PROG [-h] [--foo | --bar]\n" \
      "PROG: error: argument --bar: not allowed with argument --foo\n")
  end

  it "requires one argument of a required mutually exclusive group" do
    parser = recording_parser
    group = parser.add_mutually_exclusive_group(required: true)
    group.add_argument("-a")
    group.add_argument("-b")
    stderr_for(parser, [] of String).should eq(
      "usage: PROG [-h] (-a A | -b B)\n" \
      "PROG: error: one of the arguments -a -b is required\n")
  end

  it "keeps optional positionals out of required messages" do
    parser = RecordingParser.new(prog: "PROG", usage: "")
    parser.add_argument("req_pos")
    parser.add_argument("optional_positional", nargs: "?", default: "eggs")
    stderr_for(parser, [] of String).should eq(
      "usage: \n" \
      "PROG: error: the following arguments are required: req_pos\n")
  end
end

describe "parse_known_args" do
  it "returns unrecognized options as extras" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("--foo")
    namespace, extras = parser.parse_known_args(["--foo", "F", "--bar", "--baz"])
    namespace.should eq(namespace(foo: "F"))
    extras.should eq(["--bar", "--baz"])
  end

  it "interleaves positionals and optionals" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("-v", nargs: "?", const: 1_i64, type: "int")
    parser.add_argument("--spam", action: "store_false")
    parser.add_argument("badger")
    namespace, extras = parser.parse_known_args(["B", "C", "--foo", "-v", "3", "4"])
    namespace.should eq(namespace(v: 3_i64, spam: true, badger: "B"))
    extras.should eq(["C", "--foo", "4"])
  end

  it "accepts tuples and returns an empty list of extras" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("x")
    namespace, extras = parser.parse_known_args({"x"})
    namespace.should eq(namespace(x: "x"))
    extras.should be_empty
  end

  it "defaults nargs='*' positionals to an empty list" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("x", nargs: "*", choices: ["x", "y"])
    parser.parse_args([] of String).should eq(namespace(x: [] of Argparse::Value))
  end
end

describe "double dash" do
  it "treats everything after -- as positionals" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("-f", "--foo")
    parser.add_argument("bar", nargs: "*")

    parser.parse_args(["--foo=--"]).should eq(namespace(foo: "--", bar: [] of Argparse::Value))
    parser.parse_args(["-f--"]).should eq(namespace(foo: "--", bar: [] of Argparse::Value))
    parser.parse_args(["--foo", "a", "--", "b", "c"]).should eq(
      namespace(foo: "a", bar: ["b", "c"] of Argparse::Value))
    parser.parse_args(["a", "b", "--foo", "c"]).should eq(
      namespace(foo: "c", bar: ["a", "b"] of Argparse::Value))
    parser.parse_args(["a", "--", "b", "--foo", "c"]).should eq(
      namespace(foo: nil, bar: ["a", "b", "--foo", "c"] of Argparse::Value))
    parser.parse_args(["a", "--", "b", "--", "c", "--foo", "d"]).should eq(
      namespace(foo: nil, bar: ["a", "b", "--", "c", "--foo", "d"] of Argparse::Value))

    expect_raises(Argparse::ArgumentError, "argument -f/--foo: expected one argument") do
      parser.parse_args(["--foo", "--"])
    end
    expect_raises(Argparse::ArgumentError, "argument -f/--foo: expected one argument") do
      parser.parse_args(["-f", "--"])
    end
  end

  it "stops a nargs='*' option at --" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("-f", "--foo", nargs: "*")
    parser.add_argument("bar", nargs: "*")

    parser.parse_args(["--foo=--"]).should eq(namespace(foo: ["--"] of Argparse::Value, bar: [] of Argparse::Value))
    parser.parse_args(["--foo", "--"]).should eq(namespace(foo: [] of Argparse::Value, bar: [] of Argparse::Value))
    parser.parse_args(["-f--"]).should eq(namespace(foo: ["--"] of Argparse::Value, bar: [] of Argparse::Value))
    parser.parse_args(["-f", "--"]).should eq(namespace(foo: [] of Argparse::Value, bar: [] of Argparse::Value))
    parser.parse_args(["--foo", "a", "b", "--", "c", "d"]).should eq(
      namespace(foo: ["a", "b"] of Argparse::Value, bar: ["c", "d"] of Argparse::Value))
    parser.parse_args(["a", "b", "--foo", "c", "d"]).should eq(
      namespace(foo: ["c", "d"] of Argparse::Value, bar: ["a", "b"] of Argparse::Value))
    parser.parse_args(["a", "--", "b", "--foo", "c", "d"]).should eq(
      namespace(foo: nil, bar: ["a", "b", "--foo", "c", "d"] of Argparse::Value))

    namespace, extras = parser.parse_known_args(["a", "b", "--foo", "c", "--", "d"])
    namespace.should eq(namespace(foo: ["c"] of Argparse::Value, bar: ["a", "b"] of Argparse::Value))
    extras.should eq(["--", "d"])
  end

  it "handles several -- markers" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("foo")
    parser.add_argument("bar", nargs: "*")

    parser.parse_args(["--", "a", "b", "c"]).should eq(namespace(foo: "a", bar: ["b", "c"] of Argparse::Value))
    parser.parse_args(["a", "--", "b", "c"]).should eq(namespace(foo: "a", bar: ["b", "c"] of Argparse::Value))
    parser.parse_args(["a", "b", "--", "c"]).should eq(namespace(foo: "a", bar: ["b", "c"] of Argparse::Value))
    parser.parse_args(["a", "--", "b", "--", "c"]).should eq(
      namespace(foo: "a", bar: ["b", "--", "c"] of Argparse::Value))
    parser.parse_args(["--", "--", "a", "--", "b", "c"]).should eq(
      namespace(foo: "--", bar: ["a", "--", "b", "c"] of Argparse::Value))
  end

  it "keeps -- inside a remainder positional" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("foo")
    parser.add_argument("bar", nargs: "...")

    parser.parse_args(["--", "a", "b", "c"]).should eq(namespace(foo: "a", bar: ["b", "c"] of Argparse::Value))
    parser.parse_args(["a", "--", "b", "c"]).should eq(namespace(foo: "a", bar: ["b", "c"] of Argparse::Value))
    parser.parse_args(["a", "b", "--", "c"]).should eq(namespace(foo: "a", bar: ["b", "--", "c"] of Argparse::Value))
    parser.parse_args(["a", "--", "b", "--", "c"]).should eq(namespace(foo: "a", bar: ["b", "--", "c"] of Argparse::Value))

    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("--foo")
    parser.add_argument("bar", nargs: "...")
    parser.parse_args(["--foo", "a", "--", "b", "--", "c"]).should eq(
      namespace(foo: "a", bar: ["--", "b", "--", "c"] of Argparse::Value))
  end
end

describe "namespace" do
  it "contains only supplied destinations" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("--foo", action: "store_true", default: Argparse::SUPPRESS)
    parser.add_argument("--bar")
    namespace = parser.parse_args(["a"] of String) rescue nil
    namespace = parser.parse_args([] of String)
    namespace.has_key?("foo").should be_false
    namespace.has_key?("bar").should be_true
  end

  it "applies parser level defaults" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("--w")
    parser.add_argument("--x", default: "XX")
    parser.add_argument("y", nargs: "?")
    parser.add_argument("z", nargs: "?", default: "ZZ")
    parser.parse_args([] of String).should eq(
      namespace(w: nil, x: "XX", y: nil, z: "ZZ"))

    parser.set_defaults(w: "WW", x: "X", y: "YY", z: "Z")
    parser.parse_args([] of String).should eq(
      namespace(w: "WW", x: "X", y: "YY", z: "Z"))
  end

  it "reports defaults like get_default" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.get_default("foo").should eq(Argparse::UNSET)
    parser.add_argument("--foo")
    parser.get_default("foo").should eq(Argparse::UNSET)
    parser.add_argument("--bar", type: "int", default: 42_i64)
    parser.get_default("bar").should eq(42_i64)
    parser.set_defaults(foo: "badger")
    parser.get_default("foo").should eq("badger")
  end
end

describe "type conversion" do
  it "calls a converter exactly once per value" do
    calls = [] of String
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("--foo") { |value| calls << value; value.as(Argparse::Value) }
    parser.parse_args(["--foo", "a"] of String)
    calls.should eq(["a"])
    parser.parse_args([] of String)
    calls.should eq(["a"])
  end

  it "does not convert values that were not supplied" do
    calls = 0
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("--foo", default: "default") do |value|
      calls += 1
      value.as(Argparse::Value)
    end
    parser.parse_args([] of String).should eq(namespace(foo: "default"))
    calls.should eq(1)
  end

  it "converts string defaults of unused arguments" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("--foo", type: "int", default: "42")
    parser.parse_args([] of String).should eq(namespace(foo: 42_i64))
  end
end

describe "mutually exclusive groups" do
  it "parses one option of a group" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    group = parser.add_mutually_exclusive_group
    group.add_argument("--bar")
    group.add_argument("--baz", nargs: "?", const: "Z")

    parser.parse_args(["--bar", "X"]).should eq(namespace(bar: "X", baz: nil))
    parser.parse_args(["--bar", "X", "--bar", "Z"]).should eq(namespace(bar: "Z", baz: nil))
    parser.parse_args(["--baz", "Y"]).should eq(namespace(bar: nil, baz: "Y"))
    parser.parse_args(["--baz"]).should eq(namespace(bar: nil, baz: "Z"))
    expect_raises(Argparse::ArgumentError, "argument --baz: not allowed with argument --bar") do
      parser.parse_args(["--bar", "X", "--baz", "Y"])
    end
  end

  it "treats nargs='?' groups correctly when required" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    group = parser.add_mutually_exclusive_group(required: true)
    group.add_argument("--foo")
    group.add_argument("--bar", nargs: "?")

    parser.parse_args(["--foo", "X"]).should eq(namespace(foo: "X", bar: nil))
    parser.parse_args(["--bar", "X"]).should eq(namespace(foo: nil, bar: "X"))
    parser.parse_args(["--bar"]).should eq(namespace(foo: nil, bar: nil))
    expect_raises(Argparse::ArgumentError, "one of the arguments --foo --bar is required") do
      parser.parse_args([] of String)
    end
  end

  it "formats usage and help with group brackets" do
    parser = Argparse::ArgumentParser.new(prog: "PROG")
    first = parser.add_mutually_exclusive_group
    first.add_argument("--foo", action: "store_true")
    first.add_argument("--bar", action: "store_false")
    second = parser.add_mutually_exclusive_group
    second.add_argument("--soup", action: "store_true")
    second.add_argument("--nuts", action: "store_false")

    parser.format_help.should eq(
      "usage: PROG [-h] [--foo | --bar] [--soup | --nuts]\n" \
      "\n" \
      "options:\n" \
      "  -h, --help  show this help message and exit\n" \
      "  --foo\n" \
      "  --bar\n" \
      "  --soup\n" \
      "  --nuts\n")
  end

  it "rejects positional arguments in a group" do
    parser = Argparse::ArgumentParser.new
    group = parser.add_mutually_exclusive_group
    expect_raises(Argparse::ConfigurationError) { group.add_argument("bar") }
  end
end

# Local aliases so the examples above read like the upstream tests.
private def expect_raises(klass : Argparse::ArgumentError.class, message : String, &block)
  error = expect_raises(klass, &block)
  error.message.should eq(message)
  error
end
