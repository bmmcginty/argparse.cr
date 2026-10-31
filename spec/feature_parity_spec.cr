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
