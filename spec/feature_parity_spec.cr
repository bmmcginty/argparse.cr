require "./spec_helper"

# Additional hand-written coverage for features that are not described by a
# CPython `ParserTestCase` or `HelpTestCase` subclass.

private def values(**pairs) : Argparse::Namespace
  result = Hash(String, Argparse::Value).new
  pairs.each { |key, value| result[key.to_s] = value }
  Argparse::Namespace.new(result)
end

describe "argument groups" do
  it "keeps declaration order across groups" do
    parser = Argparse::ArgumentParser.new(exit_on_error: false)
    parser.add_argument("foo")
    group = parser.add_argument_group("g")
    group.add_argument("bar")
    parser.add_argument("baz")
    parser.parse_args(["1", "2", "3"]).should eq(values(foo: "1", bar: "2", baz: "3"))
  end

  it "renders group titles and descriptions" do
    parser = Argparse::ArgumentParser.new(prog: "PROG")
    group = parser.add_argument_group("g", "gd")
    group.add_argument("-w")
    group.add_argument("-x")
    parser.format_help.should eq(
      "usage: PROG [-h] [-w W] [-x X]\n" \
      "\n" \
      "options:\n" \
      "  -h, --help  show this help message and exit\n" \
      "\n" \
      "g:\n" \
      "  gd\n" \
      "\n" \
      "  -w W\n" \
      "  -x X\n")
  end

  it "supports mutually exclusive groups inside argument groups" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    group = parser.add_argument_group("g")
    mutex = group.add_mutually_exclusive_group
    mutex.add_argument("-y", action: "store_true")
    mutex.add_argument("-z", action: "store_true")
    expect_raises(Argparse::ArgumentError, "argument -z: not allowed with argument -y") do
      parser.parse_args(["-y", "-z"])
    end
  end
end

describe "parent parsers" do
  it "copies arguments, groups, and mutually exclusive groups" do
    parent = Argparse::ArgumentParser.new(add_help: false)
    named = parent.add_argument_group("g", "gd")
    named.add_argument("-w")
    named.add_argument("-x")
    mutex = parent.add_mutually_exclusive_group
    mutex.add_argument("-y")
    mutex.add_argument("-z")

    parser = Argparse::ArgumentParser.new(prog: "PROG", parents: [parent], exit_on_error: false)
    parser.format_help.should eq(
      "usage: PROG [-h] [-w W] [-x X] [-y Y | -z Z]\n" \
      "\n" \
      "options:\n" \
      "  -h, --help  show this help message and exit\n" \
      "  -y Y\n" \
      "  -z Z\n" \
      "\n" \
      "g:\n" \
      "  gd\n" \
      "\n" \
      "  -w W\n" \
      "  -x X\n")
    expect_raises(Argparse::ArgumentError, "argument -z: not allowed with argument -y") do
      parser.parse_args(["-y", "Y", "-z", "Z"])
    end
  end
end

describe "conflict handling" do
  it "replaces old option strings with conflict_handler: resolve" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", conflict_handler: "resolve")
    parser.add_argument("-x", help: "OLD X")
    parser.add_argument("-x", help: "NEW X")
    parser.format_help.should eq(
      "usage: PROG [-h] [-x X]\n" \
      "\n" \
      "options:\n" \
      "  -h, --help  show this help message and exit\n" \
      "  -x X        NEW X\n")
  end
end

describe "subparsers" do
  it "dispatches to a subparser and merges its namespace" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--foo", action: "store_true")
    parser.add_argument("bar", type: "float")
    subparsers = parser.add_subparsers(help: "command help")
    one = subparsers.add_parser("1", description: "1 description")
    one.add_argument("-w", type: "int")
    one.add_argument("x")

    namespace = parser.parse_args(["--foo", "0.125", "1", "c", "-w", "7"])
    namespace.should eq(values(foo: true, bar: 0.125, w: 7_i64, x: "c"))
  end

  it "supports aliases, dest, and required subcommands" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    subparsers = parser.add_subparsers(dest: "bar", required: true)
    subparsers.add_parser("fullname", aliases: ["alias"], help: "the full name")

    parser.parse_args(["alias"]).should eq(values(bar: "alias"))
    expect_raises(Argparse::ArgumentError, "the following arguments are required: {fullname,alias}") do
      parser.parse_args([] of String)
    end
  end

  it "formats subcommands in usage and help" do
    parser = Argparse::ArgumentParser.new(prog: "PROG")
    parser.add_argument("--foo", action: "store_true", help: "foo help")
    parser.add_argument("bar", type: "float", help: "bar help")
    subparsers = parser.add_subparsers(help: "command help")
    one = subparsers.add_parser("1", help: "1 help", description: "1 description")
    one.add_argument("-w", type: "int", help: "w help")
    one.add_argument("x", choices: ["a", "b", "c"], help: "x help")
    subparsers.add_parser("2", help: "2 help")

    parser.format_usage.should eq("usage: PROG [-h] [--foo] bar {1,2} ...\n")
    parser.format_help.should eq(
      "usage: PROG [-h] [--foo] bar {1,2} ...\n" \
      "\n" \
      "positional arguments:\n" \
      "  bar         bar help\n" \
      "  {1,2}       command help\n" \
      "    1         1 help\n" \
      "    2         2 help\n" \
      "\n" \
      "options:\n" \
      "  -h, --help  show this help message and exit\n" \
      "  --foo       foo help\n")
  end

  it "uses the subparser prog for its own errors" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("bar", type: "float")
    subparsers = parser.add_subparsers
    subparsers.add_parser("1", exit_on_error: false).add_argument("x")
    error = expect_raises(Argparse::ArgumentError) { parser.parse_args(["0.5", "1"]) }
    error.message.should eq("the following arguments are required: x")
  end

  it "rejects duplicate subparser names and aliases" do
    parser = Argparse::ArgumentParser.new
    subparsers = parser.add_subparsers
    subparsers.add_parser("fullname", aliases: ["alias"])
    expect_raises(Argparse::ConfigurationError, "conflicting subparser: fullname") do
      subparsers.add_parser("fullname")
    end
    expect_raises(Argparse::ConfigurationError, "conflicting subparser alias: alias") do
      subparsers.add_parser("other", aliases: ["alias"])
    end
  end
end

private class SplitLineParser < Argparse::ArgumentParser
  def convert_arg_line_to_args(arg_line : String) : Array(String)
    arg_line.split(/\s+/).reject(&.empty?)
  end
end

describe "argument files" do
  it "expands fromfile references recursively" do
    dir = Dir.tempdir
    hello = File.join(dir, "argparse-hello-#{Process.pid}")
    recursive = File.join(dir, "argparse-recursive-#{Process.pid}")
    File.write(hello, "hello world\n")
    File.write(recursive, "-a\nA\n@#{hello}")
    begin
      parser = Argparse::ArgumentParser.new(prog: "PROG", fromfile_prefix_chars: "@", exit_on_error: false)
      parser.add_argument("-a")
      parser.add_argument("x")
      parser.add_argument("y", nargs: "+")
      parser.parse_args(["X", "@#{recursive}", "Z"]).should eq(
        values(a: "A", x: "X", y: ["hello world", "Z"] of Argparse::Value))
    ensure
      File.delete(hello) rescue nil
      File.delete(recursive) rescue nil
    end
  end

  it "uses convert_arg_line_to_args to split lines" do
    path = File.join(Dir.tempdir, "argparse-split-#{Process.pid}")
    File.write(path, "hello world\n")
    begin
      parser = SplitLineParser.new(prog: "PROG", fromfile_prefix_chars: "@", exit_on_error: false)
      parser.add_argument("y", nargs: "+")
      parser.parse_args(["@#{path}", "X"]).should eq(
        values(y: ["hello", "world", "X"] of Argparse::Value))
    ensure
      File.delete(path) rescue nil
    end
  end
end

describe "intermixed parsing" do
  it "collects positionals around optionals" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--foo")
    parser.add_argument("--bar", required: true)
    parser.add_argument("cmd")
    parser.add_argument("rest", nargs: "*", type: "int")
    argv = ["cmd", "--foo", "x", "1", "--bar", "y", "2", "3"]
    parser.parse_intermixed_args(argv).should eq(
      values(foo: "x", bar: "y", cmd: "cmd", rest: [1_i64, 2_i64, 3_i64] of Argparse::Value))
  end

  it "leaves unknown options in extras" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--foo")
    parser.add_argument("--bar", required: true)
    parser.add_argument("cmd")
    parser.add_argument("rest", nargs: "*", type: "int")
    namespace, extras = parser.parse_known_intermixed_args(
      ["cmd", "--foo", "x", "--error", "1", "2", "--bar", "y", "3"])
    namespace.should eq(values(foo: "x", bar: "y", cmd: "cmd", rest: [1_i64, 2_i64, 3_i64] of Argparse::Value))
    extras.should eq(["--error"])
  end

  it "rejects positional remainder arguments" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("x")
    parser.add_argument("y", nargs: "...")
    expect_raises(Argparse::ConfigurationError, /nargs=\.\.\./) do
      parser.parse_intermixed_args(["X", "A"])
    end
  end
end

describe "parse namespace" do
  it "fills an existing namespace without replacing existing keys" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--foo")
    parser.add_argument("bar")
    namespace = values(foo: "old", extra: 1_i64)
    result = parser.parse_args(["--foo", "new", "value"], namespace)
    result.should be(namespace)
    result.should eq(values(foo: "new", bar: "value", extra: 1_i64))
  end
end

describe "formatter classes" do
  it "adds defaults with ArgumentDefaultsHelpFormatter" do
    parser = Argparse::ArgumentParser.new(
      prog: "PROG", description: "description",
      formatter_class: Argparse::ArgumentDefaultsHelpFormatter)
    parser.add_argument("--foo", help: "foo help - oh and by the way, %(default)s")
    parser.add_argument("--bar", action: "store_true", help: "bar help")
    parser.add_argument("--quux", help: "Set the quux", default: 42_i64)
    parser.add_argument("spam", help: "spam help")
    parser.add_argument("badger", nargs: "?", default: "wooden", help: "badger help")
    parser.format_help.should eq(
      "usage: PROG [-h] [--foo FOO] [--bar] [--quux QUUX] spam [badger]\n" \
      "\n" \
      "description\n" \
      "\n" \
      "positional arguments:\n" \
      "  spam         spam help\n" \
      "  badger       badger help (default: wooden)\n" \
      "\n" \
      "options:\n" \
      "  -h, --help   show this help message and exit\n" \
      "  --foo FOO    foo help - oh and by the way, None\n" \
      "  --bar        bar help (default: False)\n" \
      "  --quux QUUX  Set the quux (default: 42)\n")
  end

  it "uses type names with MetavarTypeHelpFormatter" do
    parser = Argparse::ArgumentParser.new(
      prog: "PROG", description: "description",
      formatter_class: Argparse::MetavarTypeHelpFormatter)
    parser.add_argument("a", type: "int")
    parser.add_argument("-b", type: "str")
    parser.add_argument("-c", type: "float", metavar: "SOME FLOAT")
    parser.format_usage.should eq("usage: PROG [-h] [-b str] [-c SOME FLOAT] int\n")
  end

  it "preserves raw descriptions but not raw help text" do
    parser = Argparse::ArgumentParser.new(
      prog: "PROG", formatter_class: Argparse::RawDescriptionHelpFormatter,
      description: "Keep the formatting\n    exactly as it is written\n\nhere\n")
    parser.add_argument("--foo", help: "  foo help should not\n    retain this odd formatting")
    parser.add_argument("spam", help: "spam help")
    parser.format_help.should eq(
      "usage: PROG [-h] [--foo FOO] spam\n" \
      "\n" \
      "Keep the formatting\n" \
      "    exactly as it is written\n" \
      "\n" \
      "here\n" \
      "\n" \
      "positional arguments:\n" \
      "  spam        spam help\n" \
      "\n" \
      "options:\n" \
      "  -h, --help  show this help message and exit\n" \
      "  --foo FOO   foo help should not retain this odd formatting\n")
  end

  it "accepts a formatter factory" do
    factory = ->(prog : String) { Argparse::HelpFormatter.new(prog, indent_increment: 5) }
    parser = Argparse::ArgumentParser.new(
      prog: "PROG", prefix_chars: "-+", formatter_class: factory)
    parser.add_argument("+f", "++foo", help: "foo help")
    parser.add_argument("spam", help: "spam help")
    parser.format_help.should eq(
      "usage: PROG [-h] [+f FOO] spam\n" \
      "\n" \
      "positional arguments:\n" \
      "     spam           spam help\n" \
      "\n" \
      "options:\n" \
      "     -h, --help     show this help message and exit\n" \
      "     +f, ++foo FOO  foo help\n")
  end
end

describe "tuple metavars and suppressed arguments" do
  it "formats tuple metavars for optionals and positionals" do
    parser = Argparse::ArgumentParser.new(prog: "PROG")
    parser.add_argument("-w", help: "w", nargs: "+", metavar: {"W1", "W2"})
    parser.add_argument("-x", help: "x", nargs: "*", metavar: {"X1", "X2"})
    parser.add_argument("-y", help: "y", nargs: 3, metavar: {"Y1", "Y2", "Y3"})
    parser.add_argument("-z", help: "z", nargs: "?", metavar: {"Z1"})
    parser.format_usage.should eq(
      "usage: PROG [-h] [-w W1 [W2 ...]] [-x [X1 [X2 ...]]] [-y Y1 Y2 Y3] [-z [Z1]]\n")

    parser = Argparse::ArgumentParser.new(prog: "PROG")
    parser.add_argument("w", help: "w help", nargs: "+", metavar: {"W1", "W2"})
    parser.add_argument("x", help: "x help", nargs: "*", metavar: {"X1", "X2"})
    parser.add_argument("y", help: "y help", nargs: 3, metavar: {"Y1", "Y2", "Y3"})
    parser.add_argument("z", help: "z help", nargs: "?", metavar: {"Z1"})
    parser.format_usage.should eq(
      "usage: PROG [-h] W1 [W2 ...] [X1 [X2 ...]] Y1 Y2 Y3 [Z1]\n")
    parser.format_help.should contain("  W1 W2       w help\n")
    parser.format_help.should contain("  Y1 Y2 Y3    y help\n")
  end

  it "rejects tuple metavars that do not match nargs" do
    parser = Argparse::ArgumentParser.new
    expect_raises(Argparse::ConfigurationError, "length of metavar tuple does not match nargs") do
      parser.add_argument("-x", nargs: 3, metavar: {"A", "B"})
    end
  end

  it "can suppress destinations and argument consumption" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--foo", dest: Argparse::SUPPRESS)
    parser.add_argument("--bar", nargs: Argparse::SUPPRESS)
    parser.add_argument("rest", nargs: "*")
    namespace = parser.parse_args(["--foo", "x", "--bar", "ignored", "y"])
    namespace.has_key?("foo").should be_false
    namespace["bar"].should be_nil
    namespace["rest"].should eq(["ignored", "y"] of Argparse::Value)
  end
end

describe "type converters" do
  it "accepts a Proc as type" do
    doubler = ->(value : String) { (value.to_i64 * 2).as(Argparse::Value) }
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--number", type: doubler)
    parser.parse_args(["--number", "21"]).should eq(values(number: 42_i64))
  end

  it "reports ArgumentTypeError messages from a converter" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--number") do |value|
      raise Argparse::ArgumentTypeError.new("not a lucky number: #{value}") if value == "13"
      value.as(Argparse::Value)
    end
    expect_raises(Argparse::ArgumentError, "argument --number: not a lucky number: 13") do
      parser.parse_args(["--number", "13"])
    end
  end

  it "opens files with FileType" do
    path = File.join(Dir.tempdir, "argparse-filetype-#{Process.pid}")
    File.write(path, "contents")
    begin
      parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
      parser.add_argument("--input", type: Argparse::FileType.new("r"))
      namespace = parser.parse_args(["--input", path])
      file = namespace["input"].as(IO)
      file.gets_to_end.should eq("contents")
      file.close
    ensure
      File.delete(path) rescue nil
    end
  end

  it "reports FileType failures as argument errors" do
    parser = Argparse::ArgumentParser.new(prog: "PROG", exit_on_error: false)
    parser.add_argument("--input", type: Argparse::FileType.new("r"))
    expect_raises(Argparse::ArgumentError, /argument --input: can't open/) do
      parser.parse_args(["--input", "/definitely/not/a/file"])
    end
  end
end
