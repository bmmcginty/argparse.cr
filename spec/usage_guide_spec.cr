require "./spec_helper"

# A usage guide for the Python-argparse compatibility features.
#
# Each example intentionally demonstrates one feature instead of exhaustively
# testing it.  Deeper conformance coverage lives in the cpython_* specs and in
# feature_parity_spec.cr.

private def usage_values(**pairs) : Argparse::Namespace
  result = Hash(String, Argparse::Value).new
  pairs.each { |key, value| result[key.to_s] = value }
  Argparse::Namespace.new(result)
end

private class UsageWarningParser < Argparse::ArgumentParser
  getter warnings = [] of String

  def warning(message : String) : Nil
    @warnings << message
  end
end

private class UsageSplitLineParser < Argparse::ArgumentParser
  def convert_arg_line_to_args(arg_line : String) : Array(String)
    arg_line.split(/\s+/).reject(&.empty?)
  end
end

private class UsageAction < Argparse::Action
  def call(parser : Argparse::ArgumentParser, namespace : Argparse::Namespace,
           values : Argparse::Value, option_string : String?) : Nil
    namespace["word"] = values.as(String).upcase
  end
end

private class UsageExitParser < Argparse::ArgumentParser
  class Exited < Exception
  end

  getter status : Int32? = nil
  getter exit_message : String? = nil

  def exit(status : Int32 = 0, message : String? = nil) : NoReturn
    @status = status
    @exit_message = message
    raise Exited.new
  end
end

describe "usage guide" do
  it "groups arguments and can put a mutually exclusive group inside" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    network = parser.add_argument_group("network", "connection settings")
    transport = network.add_mutually_exclusive_group(required: true)
    transport.add_argument("--tcp", action: "store_true", help: "use TCP")
    transport.add_argument("--udp", action: "store_true", help: "use UDP")

    parser.parse_args(["--tcp"]).should eq(usage_values(tcp: true, udp: false))
    parser.format_help.should contain("network:")
  end

  it "inherits arguments from parent parsers" do
    common = Argparse::ArgumentParser.new(add_help: false)
    common.add_argument("--verbose", action: "store_true")

    parser = Argparse::ArgumentParser.new(prog: "demo", parents: [common],
      exit_on_error: false)
    parser.add_argument("file")
    parser.parse_args(["--verbose", "input.txt"]).should eq(
      usage_values(verbose: true, file: "input.txt"))
  end

  it "resolves conflicting option strings" do
    parser = Argparse::ArgumentParser.new(prog: "demo", conflict_handler: "resolve",
      exit_on_error: false)
    parser.add_argument("-x", help: "old spelling")
    parser.add_argument("-x", help: "new spelling")
    parser.format_help.should contain("new spelling")
  end

  it "selects a built-in help formatter" do
    parser = Argparse::ArgumentParser.new(prog: "demo",
      formatter_class: Argparse::ArgumentDefaultsHelpFormatter)
    parser.add_argument("--port", default: 8080_i64, help: "listen port")
    parser.format_help.should contain("(default: 8080)")
  end

  it "supplies a custom formatter factory" do
    factory = ->(prog : String) { Argparse::HelpFormatter.new(prog, indent_increment: 4) }
    parser = Argparse::ArgumentParser.new(prog: "demo", formatter_class: factory)
    parser.add_argument("--verbose", action: "store_true", help: "more output")
    parser.format_help.should contain("    --verbose")
  end

  it "dispatches subcommands, aliases, and required commands" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    commands = parser.add_subparsers(dest: "command", required: true, help: "command to run")
    serve = commands.add_parser("serve", aliases: ["s"], help: "start serving")
    serve.add_argument("--port", type: "int", default: 8080_i64)

    parser.parse_args(["s", "--port", "9000"]).should eq(
      usage_values(command: "s", port: 9000_i64))
  end

  it "uses tuple metavars for multi-value arguments" do
    parser = Argparse::ArgumentParser.new(prog: "demo")
    parser.add_argument("--point", nargs: 2, metavar: {"X", "Y"})
    parser.format_usage.should eq("usage: demo [-h] [--point X Y]\n")
  end

  it "suppresses destinations and consumed arguments" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--internal", dest: Argparse::SUPPRESS)
    parser.add_argument("--reset", nargs: Argparse::SUPPRESS)
    namespace = parser.parse_args(["--internal", "secret", "--reset"])
    namespace.has_key?("internal").should be_false
    namespace["reset"].should be_nil
  end

  it "warns about deprecated options and subcommands" do
    parser = UsageWarningParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--old", deprecated: true)
    commands = parser.add_subparsers(dest: "command")
    commands.add_parser("legacy", deprecated: true)

    parser.parse_args(["--old", "value", "legacy"])
    parser.warnings.should eq([
      "option '--old' is deprecated",
      "command 'legacy' is deprecated",
    ])
  end

  it "defines and registers custom actions" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--word", action: UsageAction.new)
    parser.parse_args(["--word", "hello"]).should eq(usage_values(word: "HELLO"))

    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.register_action("shout", UsageAction)
    parser.add_argument("--word", action: "shout")
    parser.parse_args(["--word", "again"]).should eq(usage_values(word: "AGAIN"))
  end

  it "uses a Proc as a type converter" do
    double = ->(value : String) { (value.to_i64 * 2).as(Argparse::Value) }
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--number", type: double)
    parser.parse_args(["--number", "21"]).should eq(usage_values(number: 42_i64))
  end

  it "reports ArgumentTypeError messages from converters" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--age") do |value|
      raise Argparse::ArgumentTypeError.new("age must be positive") if value.to_i <= 0
      value.as(Argparse::Value)
    end
    expect_raises(Argparse::ArgumentError, "argument --age: age must be positive") do
      parser.parse_args(["--age", "0"])
    end
  end

  it "opens files with FileType" do
    path = File.join(Dir.tempdir, "argparse-usage-#{Process.pid}")
    File.write(path, "hello")
    begin
      parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
      parser.add_argument("--input", type: Argparse::FileType.new("r"))
      namespace = parser.parse_args(["--input", path])
      file = namespace["input"].as(IO)
      file.gets_to_end.should eq("hello")
      file.close
    ensure
      File.delete(path) rescue nil
    end
  end

  it "parses into an existing namespace" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--name")
    namespace = usage_values(extra: "kept")
    parser.parse_args(["--name", "crystal"], namespace)
    namespace.should eq(usage_values(name: "crystal", extra: "kept"))
  end

  it "parses positionals intermixed with options" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--tag")
    parser.add_argument("files", nargs: "*")
    parser.parse_intermixed_args(["a", "--tag", "x", "b"]).should eq(
      usage_values(tag: "x", files: ["a", "b"] of Argparse::Value))
  end

  it "reads arguments from files and can customize line parsing" do
    path = File.join(Dir.tempdir, "argparse-usage-args-#{Process.pid}")
    File.write(path, "hello world\n")
    begin
      parser = UsageSplitLineParser.new(prog: "demo", fromfile_prefix_chars: "@",
        exit_on_error: false)
      parser.add_argument("words", nargs: "+")
      parser.parse_args(["@#{path}"]).should eq(
        usage_values(words: ["hello", "world"] of Argparse::Value))
    ensure
      File.delete(path) rescue nil
    end
  end

  it "suggests a close choice for a typo" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false,
      suggest_on_error: true)
    parser.add_argument("mode", choices: ["fast", "safe"])
    expect_raises(Argparse::ArgumentError,
      "argument mode: invalid choice: 'saf', maybe you meant 'safe'? (choose from 'fast', 'safe')") do
      parser.parse_args(["saf"])
    end
  end

  it "translates emitted messages" do
    previous = Argparse.translator
    begin
      Argparse.translator = ->(message : String) { message.upcase }
      Argparse.translate("show this help message and exit").should eq(
        "SHOW THIS HELP MESSAGE AND EXIT")
    ensure
      Argparse.translator = previous
    end
  end

  it "prints messages and exits with a status" do
    parser = UsageExitParser.new(prog: "demo")
    io = IO::Memory.new
    parser.print_message("hello\n", io)
    io.to_s.should eq("hello\n")

    expect_raises(UsageExitParser::Exited) { parser.exit(3, "goodbye\n") }
    parser.status.should eq(3)
    parser.exit_message.should eq("goodbye\n")
  end

  it "exposes nargs constants and BooleanOptionalAction" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--color", action: Argparse::BooleanOptionalAction)
    parser.parse_args(["--no-color"]).should eq(usage_values(color: false))
    Argparse::ONE_OR_MORE.should eq("+")
    Argparse::PARSER.should eq("A...")
  end

  it "parses complex numbers" do
    parser = Argparse::ArgumentParser.new(prog: "demo", exit_on_error: false)
    parser.add_argument("--value", type: "complex")
    value = parser.parse_args(["--value", "2j"])["value"].as(Complex)
    value.real.should eq(0.0)
    value.imag.should eq(2.0)
  end
end
