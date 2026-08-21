# A small, dependency-free command line parser modelled after Python's argparse.
module Argparse
  VERSION = "0.1.0"

  alias Scalar = String | Int64 | Float64 | Bool
  alias Value = Scalar | Array(Scalar) | Nil

  class Error < Exception
  end

  class ArgumentError < Error
  end

  class Namespace
    getter values : Hash(String, Value)

    def initialize(@values = {} of String => Value)
    end

    def [](name : String | Symbol) : Value
      @values[name.to_s]?
    end

    def []?(name : String | Symbol) : Value
      self[name]
    end

    def has_key?(name : String | Symbol) : Bool
      @values.has_key?(name.to_s)
    end

    def string(name : String | Symbol) : String?
      case value = self[name]
      when String               then value
      when Int64, Float64, Bool then value.to_s
      else                           nil
      end
    end

    def int(name : String | Symbol) : Int64?
      case value = self[name]
      when Int64  then value
      when String then value.to_i64?
      else             nil
      end
    end

    def float(name : String | Symbol) : Float64?
      case value = self[name]
      when Float64 then value
      when Int64   then value.to_f64
      when String  then value.to_f64?
      else              nil
      end
    end

    def bool(name : String | Symbol) : Bool?
      value = self[name]
      value.as?(Bool)
    end

    def array(name : String | Symbol) : Array(Scalar)?
      self[name].as?(Array(Scalar))
    end

    def to_h : Hash(String, Value)
      @values.dup
    end

    def to_s(io : IO) : Nil
      io << "Namespace("
      @values.each_with_index do |(key, value), index|
        io << ", " unless index == 0
        io << key << '=' << value.inspect
      end
      io << ')'
    end
  end

  class Argument
    getter names : Array(String)
    getter dest : String
    getter action : String
    getter nargs : String | Int32 | Nil
    getter const_value : Value
    getter default_value : Value
    getter type_name : String?
    getter choices : Array(String)?
    getter required : Bool
    getter help : String?
    getter metavar : String?
    getter option : Bool
    getter positional_index : Int32

    def initialize(@names : Array(String), @dest : String, @action : String,
                   @nargs : String | Int32 | Nil, @const_value : Value,
                   @default_value : Value, @type_name : String?,
                   @choices : Array(String)?, @required : Bool, @help : String?,
                   @metavar : String?, @option : Bool, @positional_index : Int32,
                   @converter : Proc(String, Scalar)? = nil)
    end

    def convert(value : String) : Scalar
      if converter = @converter
        return converter.call(value)
      end
      case @type_name
      when nil, "str", "string"
        value
      when "int", "integer"
        value.to_i64
      when "float"
        value.to_f64
      when "bool", "boolean"
        case value.downcase
        when "1", "true", "yes", "on"  then true
        when "0", "false", "no", "off" then false
        else                                raise ArgumentError.new("invalid boolean value: #{value.inspect}")
        end
      else
        raise ArgumentError.new("unknown argument type #{@type_name.inspect}")
      end
    rescue ex : ArgumentError
      raise ex
    rescue
      label = @type_name || "value"
      raise ArgumentError.new("invalid #{label} value: #{value.inspect}")
    end

    def display_name : String
      @option ? @names.join("/") : (@metavar || @dest.upcase)
    end
  end

  class MutuallyExclusiveGroup
    getter arguments = [] of Argument

    def initialize(@parser : ArgumentParser, @required : Bool)
    end

    def add_argument(*names : String, action : String = "store",
                     nargs : String | Int32 | Nil = nil, const : Value = nil,
                     default : Value = nil, type : String? = nil,
                     choices : Enumerable(String)? = nil, required : Bool = false,
                     help : String? = nil, metavar : String? = nil,
                     dest : String? = nil) : Argument
      argument = @parser.add_argument(*names, action: action, nargs: nargs,
        const: const, default: default, type: type, choices: choices,
        required: required, help: help, metavar: metavar, dest: dest)
      unless argument.option
        raise ArgumentError.new("mutually exclusive arguments must be optional")
      end
      @arguments << argument
      argument
    end

    def required? : Bool
      @required
    end
  end

  class ArgumentParser
    getter prog : String
    property description : String?
    property epilog : String?
    property usage : String?
    property add_help : Bool
    property allow_abbrev : Bool
    property exit_on_error : Bool

    @arguments = [] of Argument
    @groups = [] of MutuallyExclusiveGroup

    def initialize(prog : String? = nil, @usage : String? = nil,
                   @description : String? = nil, @epilog : String? = nil,
                   @add_help : Bool = true, @allow_abbrev : Bool = true,
                   @exit_on_error : Bool = true)
      @prog = prog || File.basename(PROGRAM_NAME)
      if @add_help
        add_argument("-h", "--help", action: "help", help: "show this help message and exit")
      end
    end

    def add_argument(*names : String, action : String = "store",
                     nargs : String | Int32 | Nil = nil, const : Value = nil,
                     default : Value = nil, type : String? = nil,
                     choices : Enumerable(String)? = nil, required : Bool = false,
                     help : String? = nil, metavar : String? = nil,
                     dest : String? = nil) : Argument
      add_argument_impl(names.to_a, action, nargs, const, default, type,
        choices.try(&.to_a), required, help, metavar, dest, nil)
    end

    def add_argument(*names : String, action : String = "store",
                     nargs : String | Int32 | Nil = nil, const : Value = nil,
                     default : Value = nil, choices : Enumerable(String)? = nil,
                     required : Bool = false, help : String? = nil,
                     metavar : String? = nil, dest : String? = nil,
                     &converter : String -> Scalar) : Argument
      add_argument_impl(names.to_a, action, nargs, const, default, nil,
        choices.try(&.to_a), required, help, metavar, dest, converter)
    end

    private def add_argument_impl(names, action, nargs, const, default, type,
                                  choices, required, help, metavar, explicit_dest,
                                  converter) : Argument
      raise ArgumentError.new("add_argument requires at least one name") if names.empty?
      option = names.any? { |name| name.starts_with?('-') }
      if option && names.any? { |name| !name.starts_with?('-') }
        raise ArgumentError.new("option strings and positional names cannot be mixed")
      end
      names.each do |name|
        if option && @arguments.any? { |arg| arg.names.includes?(name) }
          raise ArgumentError.new("conflicting option string: #{name}")
        end
      end
      destination = explicit_dest || infer_dest(names, option)
      normalized_action = action.gsub('-', '_')
      valid_actions = {"store", "store_const", "store_true", "store_false", "append", "append_const", "count", "help", "version"}
      unless valid_actions.includes?(normalized_action)
        raise ArgumentError.new("unknown action #{action.inspect}")
      end
      effective_nargs = case normalized_action
                        when "store_const", "store_true", "store_false", "append_const", "count", "help", "version" then 0
                        else                                                                                             nargs
                        end
      if effective_nargs.is_a?(Int32) && effective_nargs < 0
        raise ArgumentError.new("nargs must be non-negative")
      end
      position = @arguments.count { |arg| !arg.option }
      argument = Argument.new(names, destination, normalized_action, effective_nargs,
        const, default, type, choices, required, help, metavar, option, position, converter)
      @arguments << argument
      argument
    end

    private def infer_dest(names : Array(String), option : Bool) : String
      source = if option
                 names.select { |name| name.starts_with?("--") }.max_by?(&.size) || names.first
               else
                 names.first
               end
      source.lstrip('-').gsub('-', '_')
    end

    def add_mutually_exclusive_group(required : Bool = false) : MutuallyExclusiveGroup
      group = MutuallyExclusiveGroup.new(self, required)
      @groups << group
      group
    end

    def parse_args(args : Enumerable(String) = ARGV) : Namespace
      namespace, extras = parse_internal(args.to_a)
      fail_parse("unrecognized arguments: #{extras.join(" ")}") unless extras.empty?
      namespace
    rescue ex : ArgumentError
      handle_error(ex)
    end

    def parse_known_args(args : Enumerable(String) = ARGV) : Tuple(Namespace, Array(String))
      parse_internal(args.to_a)
    rescue ex : ArgumentError
      handle_error(ex)
    end

    def parse(args : Enumerable(String) = ARGV) : Namespace
      parse_args(args)
    end

    private def parse_internal(tokens : Array(String)) : Tuple(Namespace, Array(String))
      values = {} of String => Value
      seen = Set(String).new
      @arguments.each do |argument|
        initial = default_for(argument)
        values[argument.dest] = clone_value(initial) unless initial.nil?
      end

      positional_tokens = [] of String
      extras = [] of String
      options_enabled = true
      index = 0
      while index < tokens.size
        token = tokens[index]
        if options_enabled && token == "--"
          options_enabled = false
          index += 1
          next
        end
        if options_enabled && option_token?(token)
          if cluster = short_flag_cluster(token)
            cluster.each do |argument|
              if argument.action == "help"
                puts format_help
                exit(0)
              end
              apply(argument, [] of String, values)
              seen << argument.dest
            end
            index += 1
            next
          end
          argument, attached = find_option(token)
          unless argument
            extras << token
            index += 1
            next
          end
          if argument.action == "help"
            puts format_help
            exit(0)
          end
          consumed, raw_values = consume_option(argument, attached, tokens, index + 1)
          apply(argument, raw_values, values)
          seen << argument.dest
          index += consumed + 1
        else
          positional_tokens << token
          index += 1
        end
      end

      consume_positionals(positional_tokens, values, seen, extras)
      validate(values, seen)
      {Namespace.new(values), extras}
    end

    private def option_token?(token : String) : Bool
      token.size > 1 && token.starts_with?('-') && !negative_number?(token)
    end

    private def negative_number?(token : String) : Bool
      !!(token =~ /^-\d+(?:\.\d+)?$/) && !@arguments.any? { |arg| arg.option && arg.names.includes?(token) }
    end

    private def short_flag_cluster(token : String) : Array(Argument)?
      return nil unless token.starts_with?('-') && !token.starts_with?("--") && token.size > 2
      result = [] of Argument
      token[1..].each_char do |character|
        argument = @arguments.find { |item| item.option && item.names.includes?("-#{character}") && item.nargs == 0 }
        return nil unless argument
        result << argument
      end
      result
    end

    private def find_option(token : String) : Tuple(Argument?, String?)
      name, separator, attached = token.partition('=')
      if argument = @arguments.find { |arg| arg.option && arg.names.includes?(name) }
        return {argument, separator.empty? ? nil : attached}
      end
      if @allow_abbrev && name.starts_with?("--")
        matches = @arguments.select { |arg| arg.option && arg.names.any? { |candidate| candidate.starts_with?(name) } }
        return {matches.first, separator.empty? ? nil : attached} if matches.size == 1
        fail_parse("ambiguous option: #{name}") if matches.size > 1
      end
      # Python accepts joined short options such as -nVALUE.
      if name.starts_with?('-') && !name.starts_with?("--") && name.size > 2
        if argument = @arguments.find { |arg| arg.names.includes?(name[0, 2]) }
          return {argument, name[2..]}
        end
      end
      {nil, nil}
    end

    private def consume_option(argument : Argument, attached : String?, tokens : Array(String), start : Int32) : Tuple(Int32, Array(String))
      count = argument.nargs
      return {0, [] of String} if count == 0
      if attached
        return {0, [attached]}
      end
      case count
      when Int32
        fail_parse("argument #{argument.display_name}: expected #{count} argument(s)") if start + count > tokens.size
        {count, tokens[start, count]}
      when "?"
        if start < tokens.size && !option_token?(tokens[start])
          {1, [tokens[start]]}
        else
          {0, [] of String}
        end
      when "*", "+"
        result = [] of String
        cursor = start
        while cursor < tokens.size && !option_token?(tokens[cursor])
          result << tokens[cursor]
          cursor += 1
        end
        fail_parse("argument #{argument.display_name}: expected at least one argument") if count == "+" && result.empty?
        {result.size, result}
      else
        fail_parse("argument #{argument.display_name}: expected one argument") if start >= tokens.size
        {1, [tokens[start]]}
      end
    end

    private def consume_positionals(tokens, values, seen, extras) : Nil
      positionals = @arguments.reject(&.option)
      cursor = 0
      positionals.each_with_index do |argument, argument_index|
        remaining_required = positionals[(argument_index + 1)..].sum { |item| minimum_count(item) }
        available = tokens.size - cursor - remaining_required
        amount = case n = argument.nargs
                 when Int32 then n
                 when "?"   then available > 0 ? 1 : 0
                 when "*"   then Math.max(available, 0)
                 when "+"   then Math.max(available, 0)
                 else            1
                 end
        fail_parse("the following arguments are required: #{argument.dest}") if amount < minimum_count(argument)
        raw = amount > 0 ? tokens[cursor, amount] : [] of String
        apply(argument, raw, values)
        seen << argument.dest unless raw.empty?
        cursor += amount
      end
      extras.concat(tokens[cursor..]) if cursor < tokens.size
    end

    private def minimum_count(argument : Argument) : Int32
      case n = argument.nargs
      when Int32    then n
      when "?", "*" then 0
      else               1
      end
    end

    private def apply(argument : Argument, raw : Array(String), values : Hash(String, Value)) : Nil
      converted = raw.map do |value|
        if choices = argument.choices
          fail_parse("argument #{argument.display_name}: invalid choice: #{value.inspect}") unless choices.includes?(value)
        end
        argument.convert(value)
      end
      case argument.action
      when "store"
        if argument.nargs == "?" && converted.empty?
          # An absent optional positional keeps its default; an option using
          # nargs="?" receives its const value when written without a value.
          values[argument.dest] = argument.const_value if argument.option
        elsif multi_value?(argument)
          values[argument.dest] = converted
        else
          values[argument.dest] = converted.first?
        end
      when "store_const"
        values[argument.dest] = argument.const_value
      when "store_true"
        values[argument.dest] = true
      when "store_false"
        values[argument.dest] = false
      when "append"
        current = values[argument.dest]?.as?(Array(Scalar)) || [] of Scalar
        multi_value?(argument) ? current.concat(converted) : converted.each { |value| current << value }
        values[argument.dest] = current
      when "append_const"
        current = values[argument.dest]?.as?(Array(Scalar)) || [] of Scalar
        if value = argument.const_value
          if value.is_a?(Array(Scalar))
            current.concat(value)
          else
            current << value
          end
        end
        values[argument.dest] = current
      when "count"
        current = values[argument.dest]?.as?(Int64) || 0_i64
        values[argument.dest] = current + 1
      end
    end

    private def multi_value?(argument : Argument) : Bool
      n = argument.nargs
      n.is_a?(Int32) ? n != 1 : n == "*" || n == "+"
    end

    private def default_for(argument : Argument) : Value
      return argument.default_value unless argument.default_value.nil?
      case argument.action
      when "store_true"  then false
      when "store_false" then true
      when "count"       then 0_i64
      else                    nil
      end
    end

    private def clone_value(value : Value) : Value
      value.is_a?(Array(Scalar)) ? value.dup : value
    end

    private def validate(values, seen) : Nil
      missing = @arguments.select { |argument| argument.option && argument.required && !seen.includes?(argument.dest) }
      unless missing.empty?
        fail_parse("the following arguments are required: #{missing.map(&.display_name).join(", ")}")
      end
      @groups.each do |group|
        selected = group.arguments.select { |argument| seen.includes?(argument.dest) }
        if selected.size > 1
          fail_parse("argument #{selected.last.display_name}: not allowed with argument #{selected.first.display_name}")
        elsif group.required? && selected.empty?
          fail_parse("one of the arguments #{group.arguments.map(&.display_name).join(" ")} is required")
        end
      end
    end

    def format_usage : String
      return "usage: #{@usage}\n" if @usage
      parts = ["usage:", @prog]
      @groups.each do |group|
        alternatives = group.arguments.map(&.display_name).join(" | ")
        parts << (group.required? ? "(#{alternatives})" : "[#{alternatives}]")
      end
      grouped = @groups.flat_map(&.arguments)
      @arguments.each do |argument|
        next if grouped.includes?(argument)
        next if argument.action == "help"
        label = usage_label(argument)
        label = "[#{label}]" if argument.option && !argument.required
        parts << label
      end
      parts.join(' ') + "\n"
    end

    private def usage_label(argument : Argument) : String
      return positional_usage(argument) unless argument.option
      name = argument.names.find(&.starts_with?("--")) || argument.names.first
      return name if argument.nargs == 0
      "#{name} #{positional_usage(argument)}"
    end

    private def positional_usage(argument : Argument) : String
      name = argument.metavar || argument.dest.upcase
      case n = argument.nargs
      when Int32 then Array.new(n, name).join(' ')
      when "?"   then "[#{name}]"
      when "*"   then "[#{name} ...]"
      when "+"   then "#{name} [#{name} ...]"
      else            name
      end
    end

    def format_help : String
      String.build do |io|
        io << format_usage
        io << '\n'
        io << @description << "\n\n" if @description
        positionals = @arguments.reject(&.option)
        options = @arguments.select(&.option)
        write_help_section(io, "positional arguments", positionals) unless positionals.empty?
        write_help_section(io, "options", options) unless options.empty?
        io << @epilog << '\n' if @epilog
      end
    end

    private def write_help_section(io, title, arguments) : Nil
      io << title << ":\n"
      width = arguments.max_of? { |argument| help_label(argument).size } || 0
      arguments.each do |argument|
        label = help_label(argument)
        io << "  " << label
        if text = argument.help
          io << " " * (width - label.size + 2) << text.gsub("%(default)s", argument.default_value.to_s)
        end
        io << '\n'
      end
      io << '\n'
    end

    private def help_label(argument : Argument) : String
      return argument.metavar || argument.dest if !argument.option
      suffix = argument.nargs == 0 ? "" : " #{argument.metavar || argument.dest.upcase}"
      argument.names.join(", ") + suffix
    end

    private def fail_parse(message : String) : NoReturn
      raise ArgumentError.new(message)
    end

    private def handle_error(ex : ArgumentError)
      raise ex unless @exit_on_error
      STDERR << format_usage
      STDERR.puts "#{@prog}: error: #{ex.message}"
      exit(2)
    end
  end
end

alias ArgumentParser = Argparse::ArgumentParser
alias ArgumentNamespace = Argparse::Namespace
alias ArgumentParserError = Argparse::ArgumentError
