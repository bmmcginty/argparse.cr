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
