# A command line parser modelled after Python's `argparse` module.
#
# The parsing algorithm follows CPython's `argparse`: argv is classified into a
# pattern of option ("O") and argument ("A") characters, and `nargs` values are
# matched against that pattern.  Following CPython's algorithm (instead of
# rediscovering it) keeps edge cases such as `-x-1`, `-3.5`, abbreviated long
# options and interleaved positionals behaving the way they do in Python.
module Argparse
  VERSION = "0.2.0"

  # A value that can be stored in a {Namespace}.  The alias is recursive
  # because `nargs` may nest values, e.g. `append` combined with `nargs: "*"`.
  alias Value = String | Int64 | Float64 | Bool | Array(Value) | Nil

  # Placeholder for "the caller did not supply this keyword argument".
  class Unset
    def inspect(io : IO) : Nil
      io << "UNSET"
    end

    def to_s(io : IO) : Nil
      inspect(io)
    end
  end

  UNSET = Unset.new

  # Placeholder matching `argparse.SUPPRESS`: an argument with this default
  # simply does not appear in the resulting namespace.
  class Suppress
    def inspect(io : IO) : Nil
      io << "SUPPRESS"
    end

    def to_s(io : IO) : Nil
      inspect(io)
    end
  end

  SUPPRESS = Suppress.new

  # Values accepted by `const:`, `default:` and `argument_default:`.
  alias Spec = Value | Unset | Suppress

  # Normalises a value supplied through the public API into a {Spec}.
  def self.normalize(value : Object?) : Spec
    case value
    when Unset    then UNSET
    when Suppress then SUPPRESS
    else               normalize_value(value)
    end
  end

  # Normalises a single value, recursively converting containers.
  def self.normalize_value(value : Object?) : Value
    case value
    when Nil                           then nil
    when Bool                          then value
    when String                        then value
    when Symbol                        then value.to_s
    when Int8, Int16, Int32, Int64     then value.to_i64
    when UInt8, UInt16, UInt32, UInt64 then value.to_i64
    when Float32                       then value.to_f64
    when Float64                       then value
    when Enum                          then value.to_s
    when Array
      result = Array(Value).new
      value.each { |item| result << normalize_value(item) }
      result
    when Tuple
      result = Array(Value).new
      value.each { |item| result << normalize_value(item) }
      result
    when Set
      result = Array(Value).new
      value.each { |item| result << normalize_value(item) }
      result
    else
      raise ConfigurationError.new("unsupported value: #{value.inspect}")
    end
  end

  # Normalises a `choices:` argument into a list of values.
  def self.normalize_choices(value : Object?) : Array(Value)?
    return nil if value.nil?
    case value
    when Array, Tuple, Set
      result = Array(Value).new
      value.each { |item| result << normalize_value(item) }
      result
    else
      raise ConfigurationError.new("choices must be a list, not #{value.class}")
    end
  end

  class Error < Exception
  end

  # Raised for programmer errors such as an unusable `nargs`, mirroring the
  # `ValueError`s raised by CPython's `add_argument`.
  class ConfigurationError < Error
  end

  # Raised while parsing.  When an argument is involved its invocation is
  # prefixed, exactly like CPython's `argparse.ArgumentError`.
  class ArgumentError < Error
    getter argument_name : String?
    getter detail : String

    def initialize(@detail : String, @argument_name : String? = nil)
      super(@argument_name ? "argument #{@argument_name}: #{@detail}" : @detail)
    end
  end

  # Renders a value the way Python's `repr` would, so error messages match.
  def self.py_repr(value : Value) : String
    case value
    when String
      quote = value.includes?('\'') && !value.includes?('"') ? '"' : '\''
      escaped = String.build do |io|
        value.each_char do |character|
          case character
          when '\'' then io << "\\'" if quote == '\''
          when '"'  then io << "\\\"" if quote == '"'
          when '\\' then io << "\\\\"
          when '\n' then io << "\\n"
          when '\r' then io << "\\r"
          when '\t' then io << "\\t"
          else           io << character
          end
        end
      end
      "#{quote}#{escaped}#{quote}"
    when Nil   then "None"
    when true  then "True"
    when false then "False"
    when Array(Value)
      "[#{value.map { |item| py_repr(item) }.join(", ")}]"
    else
      value.to_s
    end
  end

  # Renders a value the way Python's `str` would.
  def self.py_str(value : Value) : String
    case value
    when String then value
    else             py_repr(value)
    end
  end

  # The result of a successful parse.
  class Namespace
    getter values : Hash(String, Value)

    def initialize(@values = {} of String => Value)
    end

    def [](key : String | Symbol) : Value
      @values[key.to_s]
    end

    def []?(key : String | Symbol) : Value
      @values[key.to_s]?
    end

    def []=(key : String | Symbol, value : Value) : Value
      @values[key.to_s] = value
    end

    def has_key?(key : String | Symbol) : Bool
      @values.has_key?(key.to_s)
    end

    def keys : Array(String)
      @values.keys
    end

    def to_h : Hash(String, Value)
      @values.dup
    end

    def ==(other : Namespace) : Bool
      @values == other.values
    end

    def string(key : String | Symbol) : String?
      @values[key.to_s]?.as?(String)
    end

    def int(key : String | Symbol) : Int64?
      case value = @values[key.to_s]?
      when Int64   then value
      when Float64 then value.to_i64 if value == value.trunc
      when String  then value.to_i64?
      else              nil
      end
    end

    def float(key : String | Symbol) : Float64?
      case value = @values[key.to_s]?
      when Float64 then value
      when Int64   then value.to_f64
      when String  then value.to_f64?
      else              nil
      end
    end

    def bool(key : String | Symbol) : Bool?
      @values[key.to_s]?.as?(Bool)
    end

    def array(key : String | Symbol) : Array(Value)?
      @values[key.to_s]?.as?(Array(Value))
    end

    def to_s(io : IO) : Nil
      io << "Namespace("
      @values.each_with_index do |(key, value), index|
        io << ", " unless index.zero?
        io << key << '=' << value.inspect
      end
      io << ')'
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end

  # One command line argument: either an optional (`-x`, `--foo`) or a
  # positional.
  class Argument
    getter option_strings : Array(String)
    getter dest : String
    getter action : String
    getter nargs : Nil | Int32 | String
    getter const : Spec
    property default : Spec
    getter type_name : String?
    getter choices : Array(Value)?
    property required : Bool
    getter help : String? | Suppress
    getter metavar : String?
    getter version : String?
    getter converter : Proc(String, Value)?
    property dest_suppressed : Bool
    property subparsers : SubparsersAction?

    def initialize(@option_strings : Array(String), @dest : String,
                   @action : String, @nargs : Nil | Int32 | String,
                   @const : Spec, @default : Spec, @type_name : String?,
                   @choices : Array(Value)?, @required : Bool,
                   @help : String? | Suppress, @metavar : String?,
                   @version : String?,
                   @converter : Proc(String, Value)? = nil,
                   @dest_suppressed : Bool = false,
                   @subparsers : SubparsersAction? = nil)
    end

    # True for `-x`/`--foo` style arguments.
    def option? : Bool
      !@option_strings.empty?
    end

    # The name used in error messages, mirroring `argparse._get_action_name`.
    def name : String
      return @option_strings.join('/') if option?
      if subparsers = @subparsers
        return @metavar || "{#{subparsers.choices_names.join(',')}}"
      end
      if metavar = @metavar
        return metavar
      end
      return @dest unless @dest_suppressed
      if choices = @choices
        return "{%s}" % choices.map { |choice| Argparse.py_str(choice) }.join(',') unless choices.empty?
      end
      ""
    end

    # Converts one command line word to a value.
    def convert(text : String) : Value
      if custom = @converter
        begin
          return custom.call(text)
        rescue ex : ArgumentError
          raise ex
        rescue ex
          raise ArgumentError.new(ex.message || "invalid value: #{Argparse.py_repr(text)}", name)
        end
      end
      case @type_name
      when nil, "str", "string", "String"
        text
      when "int", "integer", "Int32", "Int64"
        begin
          Argument.parse_int(text)
        rescue ex
          raise ArgumentError.new("invalid int value: #{Argparse.py_repr(text)}", name)
        end
      when "float", "Float64"
        begin
          Argument.parse_float(text)
        rescue ex
          raise ArgumentError.new("invalid float value: #{Argparse.py_repr(text)}", name)
        end
      else
        raise ConfigurationError.new("unknown argument type #{@type_name.inspect}")
      end
    end

    # Integer parsing accepting what Python's `int()` accepts.
    def self.parse_int(text : String) : Int64
      trimmed = text.strip
      unless trimmed.matches?(/\A[+-]?(?:\d(?:_?\d)*)\z/)
        raise ArgumentError.new("invalid int value: #{Argparse.py_repr(text)}")
      end
      trimmed.delete('_').to_i64
    end

    # Float parsing accepting what Python's `float()` accepts.
    def self.parse_float(text : String) : Float64
      trimmed = text.strip.delete('_')
      case trimmed.downcase
      when "inf", "+inf", "infinity", "+infinity" then Float64::INFINITY
      when "-inf", "-infinity"                    then -Float64::INFINITY
      when "nan", "+nan", "-nan"                  then Float64::NAN
      when /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/
        trimmed.to_f64
      else
        raise ArgumentError.new("invalid float value: #{Argparse.py_repr(text)}")
      end
    end
  end

  # State for an `add_subparsers` action.  The parser stores a regular
  # positional action with nargs "A..." and links it to this object.
  class SubparsersAction
    getter parser : ArgumentParser
    getter argument : Argument
    getter prog : String
    getter parser_class : ArgumentParser.class
    getter name_parser_map = {} of String => ArgumentParser
    getter choices_actions = [] of Argument
    getter deprecated_names = Set(String).new

    def initialize(@parser : ArgumentParser, @argument : Argument, @prog : String,
                   @parser_class : ArgumentParser.class)
    end

    def choices_names : Array(String)
      @name_parser_map.keys
    end

    def required? : Bool
      @argument.required
    end

    def required=(value : Bool) : Bool
      @argument.required = value
    end

    def add_parser(name : String, aliases : Array(String) = [] of String,
                   help : String? = nil, deprecated : Bool = false,
                   prog : String? = nil,
                   usage : String | Suppress | Nil = nil,
                   description : String? = nil, epilog : String? = nil,
                   parents : Array(ArgumentParser) = [] of ArgumentParser,
                   prefix_chars : String = "-",
                   fromfile_prefix_chars : String? = nil,
                   argument_default : Object? = UNSET,
                   conflict_handler : String = "error",
                   add_help : Bool = true, allow_abbrev : Bool = true,
                   exit_on_error : Bool = true,
                   width : Int32 = 78) : ArgumentParser
      if @name_parser_map.has_key?(name)
        raise ConfigurationError.new("conflicting subparser: #{name}")
      end
      aliases.each do |alias_name|
        if @name_parser_map.has_key?(alias_name)
          raise ConfigurationError.new("conflicting subparser alias: #{alias_name}")
        end
      end

      subparser_prog = prog || "#{@prog} #{name}"
      subparser = @parser_class.new(
        prog: subparser_prog, usage: usage, description: description, epilog: epilog,
        parents: parents, add_help: add_help, prefix_chars: prefix_chars,
        allow_abbrev: allow_abbrev,
        argument_default: Argparse.normalize(argument_default),
        conflict_handler: conflict_handler, exit_on_error: exit_on_error,
        fromfile_prefix_chars: fromfile_prefix_chars, width: width)

      if help
        metavar = aliases.empty? ? name : "#{name} (#{aliases.join(", ")})"
        @choices_actions << Argument.new([] of String, name, "store", nil,
          nil, nil, nil, nil, false, help, metavar, nil)
      end

      @name_parser_map[name] = subparser
      aliases.each { |alias_name| @name_parser_map[alias_name] = subparser }
      if deprecated
        @deprecated_names << name
        aliases.each { |alias_name| @deprecated_names << alias_name }
      end
      subparser
    end
  end

  # A named group of arguments.  `title` and `description` are rendered as a
  # separate section in help output, like CPython's `ArgumentGroup`.
  class ArgumentGroup
    getter parser : ArgumentParser
    getter title : String | Suppress | Nil
    getter description : String | Suppress | Nil
    getter arguments = [] of Argument
    getter required : Bool

    def initialize(@parser : ArgumentParser, @title : String | Suppress | Nil = nil,
                   @description : String | Suppress | Nil = nil,
                   @required : Bool = false)
    end

    def required? : Bool
      @required
    end

    def add_argument(*args : String, **options) : Argument
      @parser.add_group_argument(self, *args, **options)
    end

    def add_argument(*args : String, &converter : String -> Value) : Argument
      @parser.add_group_argument(self, *args, &converter)
    end

    def add_argument(names : Array(String), **options) : Argument
      @parser.add_group_argument(self, names, **options)
    end

    def add_mutually_exclusive_group(required : Bool = false) : MutuallyExclusiveGroup
      @parser.add_mutually_exclusive_group(required, self)
    end
  end

  # A group of optionals where at most one may be used.  It delegates adding
  # an action to its containing group (or the parser's normal optional /
  # positional group), then records the action as a member of the mutex.
  class MutuallyExclusiveGroup < ArgumentGroup
    getter container : ArgumentGroup?

    def initialize(parser : ArgumentParser, required : Bool,
                   @container : ArgumentGroup? = nil)
      super(parser, nil, nil, required)
    end

    def add_argument(*args : String, **options) : Argument
      @parser.add_mutex_argument(self, *args, **options)
    end

    def add_argument(*args : String, &converter : String -> Value) : Argument
      @parser.add_mutex_argument(self, *args, &converter)
    end

    def add_argument(names : Array(String), **options) : Argument
      @parser.add_mutex_argument(self, names, **options)
    end

    def add_mutually_exclusive_group(required : Bool = false) : MutuallyExclusiveGroup
      raise ConfigurationError.new("mutually exclusive groups cannot be nested")
    end
  end

  # Mutable state threaded through a single parse.
  private class ParseRun
    property namespace : Namespace
    property positionals : Array(Argument)
    getter extras = [] of String
    getter extras_pattern = [] of Char
    getter seen_actions = Set(Argument).new
    getter seen_non_default = Set(Argument).new

    def initialize(@namespace : Namespace, actions : Array(Argument))
      @positionals = actions.reject(&.option?)
    end
  end

  # One possible interpretation of an option-looking word.
  private record OptionTuple,
    action : Argument?,
    option_string : String,
    sep : String?,
    explicit_arg : String?

  class ArgumentParser
    getter prog : String
    getter usage : String | Suppress | Nil
    property description : String?
    property epilog : String?
    getter add_help : Bool
    getter prefix_chars : String
    getter allow_abbrev : Bool
    getter fromfile_prefix_chars : String?
    getter argument_default : Spec
    getter conflict_handler : String
    # Width of the formatter, like Python's `HelpFormatter` width (the
    # terminal width minus two columns).
    getter width : Int32
    property exit_on_error : Bool

    NEGATIVE_NUMBER = /\A-\.?\d/

    @actions = [] of Argument
    @option_string_actions = {} of String => Argument
    @groups = [] of MutuallyExclusiveGroup
    @argument_groups = [] of ArgumentGroup
    @positionals_group : ArgumentGroup?
    @optionals_group : ArgumentGroup?
    @has_negative_number_optionals = false
    @parser_defaults = {} of String => Spec
    @subparsers_action : SubparsersAction? = nil

    def initialize(prog : String? = nil, @usage : String | Suppress | Nil = nil,
                   @description : String? = nil, @epilog : String? = nil,
                   parents : Array(ArgumentParser) = [] of ArgumentParser,
                   @add_help : Bool = true, @prefix_chars : String = "-",
                   @allow_abbrev : Bool = true,
                   @fromfile_prefix_chars : String? = nil,
                   @argument_default : Spec = UNSET,
                   conflict_handler : String = "error",
                   @exit_on_error : Bool = true,
                   @width : Int32 = 78)
      @prog = prog || File.basename(PROGRAM_NAME)
      @conflict_handler = conflict_handler
      @argument_groups = [] of ArgumentGroup
      unless conflict_handler == "error" || conflict_handler == "resolve"
        raise ConfigurationError.new("invalid conflict_resolution value: #{conflict_handler.inspect}")
      end
      @positionals_group = ArgumentGroup.new(self, "positional arguments")
      @optionals_group = ArgumentGroup.new(self, "options")
      @argument_groups = [@positionals_group.not_nil!, @optionals_group.not_nil!] of ArgumentGroup

      if @add_help
        prefix = @prefix_chars.includes?('-') ? '-' : @prefix_chars[0]
        add_argument("#{prefix}h", "#{prefix}#{prefix}help", action: "help",
          default: SUPPRESS, help: "show this help message and exit")
      end
      parents.each { |parent| add_parent(parent) }
    end

    # ---------------------------------------------------------------
    # Defining arguments
    # ---------------------------------------------------------------

    def add_argument(*args : String, action : String | Nil = nil,
                     nargs : Int32 | String | Nil = nil,
                     const : Object? = UNSET, default : Object? = UNSET,
                     type : String | Symbol | Nil = nil,
                     choices : Object? = nil,
                     required : Bool | Nil = nil,
                     help : String | Suppress | Nil = nil,
                     metavar : String | Nil = nil,
                     dest : String | Nil = nil,
                     version : String | Nil = nil) : Argument
      add_argument_impl(args.to_a, action, nargs, const, default, type,
        choices, required, help, metavar, dest, version, nil, nil)
    end

    def add_argument(*args : String, action : String | Nil = nil,
                     nargs : Int32 | String | Nil = nil,
                     const : Object? = UNSET, default : Object? = UNSET,
                     type : String | Symbol | Nil = nil,
                     choices : Object? = nil,
                     required : Bool | Nil = nil,
                     help : String | Suppress | Nil = nil,
                     metavar : String | Nil = nil,
                     dest : String | Nil = nil,
                     version : String | Nil = nil,
                     &converter : String -> Value) : Argument
      add_argument_impl(args.to_a, action, nargs, const, default, type,
        choices, required, help, metavar, dest, version, converter, nil)
    end

    # :nodoc:
    def add_group_argument(group : ArgumentGroup, *args : String, **options) : Argument
      add_argument_impl(args.to_a, options[:action]?, options[:nargs]?,
        options.fetch(:const, UNSET), options.fetch(:default, UNSET), options[:type]?,
        options[:choices]?, options[:required]?, options[:help]?,
        options[:metavar]?, options[:dest]?, options[:version]?, nil, group)
    end

    # :nodoc:
    def add_group_argument(group : ArgumentGroup, *args : String,
                           &converter : String -> Value) : Argument
      add_argument_impl(args.to_a, nil, nil, UNSET, UNSET, nil, nil, nil,
        nil, nil, nil, nil, converter, group)
    end

    # :nodoc:
    def add_group_argument(group : ArgumentGroup, names : Array(String), **options) : Argument
      add_argument_impl(names, options[:action]?, options[:nargs]?,
        options.fetch(:const, UNSET), options.fetch(:default, UNSET), options[:type]?,
        options[:choices]?, options[:required]?, options[:help]?,
        options[:metavar]?, options[:dest]?, options[:version]?, nil, group)
    end

    # :nodoc:
    def add_mutex_argument(group : MutuallyExclusiveGroup, *args : String, **options) : Argument
      argument = add_argument_impl(args.to_a, options[:action]?, options[:nargs]?,
        options.fetch(:const, UNSET), options.fetch(:default, UNSET), options[:type]?,
        options[:choices]?, options[:required]?, options[:help]?,
        options[:metavar]?, options[:dest]?, options[:version]?, nil, group.container)
      register_mutex_argument(group, argument)
    end

    # :nodoc:
    def add_mutex_argument(group : MutuallyExclusiveGroup, *args : String,
                           &converter : String -> Value) : Argument
      argument = add_argument_impl(args.to_a, nil, nil, UNSET, UNSET, nil, nil,
        nil, nil, nil, nil, nil, converter, group.container)
      register_mutex_argument(group, argument)
    end

    # :nodoc:
    def add_mutex_argument(group : MutuallyExclusiveGroup, names : Array(String), **options) : Argument
      argument = add_argument_impl(names, options[:action]?, options[:nargs]?,
        options.fetch(:const, UNSET), options.fetch(:default, UNSET), options[:type]?,
        options[:choices]?, options[:required]?, options[:help]?,
        options[:metavar]?, options[:dest]?, options[:version]?, nil, group.container)
      register_mutex_argument(group, argument)
    end

    private def register_mutex_argument(group : MutuallyExclusiveGroup,
                                        argument : Argument) : Argument
      unless argument.option?
        raise ConfigurationError.new("mutually exclusive arguments must be optional")
      end
      group.arguments << argument
      argument
    end

    private def add_argument_impl(names : Array(String), action : String?,
                                  nargs : Int32 | String | Nil,
                                  raw_const : Object?, raw_default : Object?,
                                  raw_type : String | Symbol | Nil,
                                  raw_choices : Object?, required : Bool?,
                                  help : String | Suppress | Nil,
                                  metavar : String?, dest : String?,
                                  version : String?,
                                  converter : Proc(String, Value)?,
                                  target_group : ArgumentGroup?) : Argument
      const = Argparse.normalize(raw_const)
      default = Argparse.normalize(raw_default)
      type = raw_type.is_a?(Symbol) ? raw_type.to_s : raw_type
      choices = Argparse.normalize_choices(raw_choices)
      raise ConfigurationError.new("add_argument requires at least one name") if names.empty?

      uses_prefix = names.any? { |name| has_prefix?(name) }
      if uses_prefix
        unless names.all? { |name| has_prefix?(name) }
          raise ConfigurationError.new("invalid option string #{names.find { |name| !has_prefix?(name) }.inspect}: must start with one of #{@prefix_chars.inspect}")
        end
        destination = dest || infer_optional_dest(names)
        option_strings = names
      else
        if names.size > 1
          raise ConfigurationError.new("positional arguments cannot be given aliases: #{names.join(", ")}")
        end
        raise ConfigurationError.new("dest supplied twice for positional argument") if dest
        destination = names.first
        option_strings = [] of String
      end

      action_name = (action || "store").gsub('-', '_')
      action_name = "boolean_optional" if action_name == "BooleanOptionalAction"
      unless ACTION_NAMES.includes?(action_name)
        raise ConfigurationError.new("unknown action #{action.inspect}")
      end
      check_nargs(nargs)
      check_action_kwargs(action_name, nargs, const)

      if action_name == "boolean_optional"
        expanded = [] of String
        option_strings.each do |name|
          if name.starts_with?("--no-")
            raise ConfigurationError.new("invalid option name #{name.inspect} for BooleanOptionalAction")
          end
          expanded << name
          expanded << "--no-#{name[2..]}" if name.starts_with?("--")
        end
        option_strings = expanded
      end

      effective_nargs = case action_name
                        when "store_const", "store_true", "store_false", "append_const",
                             "count", "help", "version", "boolean_optional"
                          0
                        when "parsers"
                          "A..."
                        else
                          nargs
                        end
      required_flag = if action_name == "parsers"
                        required || false
                      elsif required.nil?
                        option_strings.empty? && !(nargs == "?" || nargs == "*")
                      else
                        required.as(Bool)
                      end
      if action_name == "version" && help.nil?
        help = "show program's version number and exit"
      end
      resolved_default = resolve_default(action_name, default, option_strings.empty?, nargs)
      resolved_const = case action_name
                       when "store_true"  then true
                       when "store_false" then false
                       else                    const.is_a?(Unset) ? nil : const
                       end

      argument = Argument.new(option_strings, destination, action_name,
        effective_nargs, resolved_const, resolved_default, type, choices,
        required_flag, help, metavar, version, converter)
      check_conflicts(argument)
      @actions << argument
      group = target_group || (option_strings.empty? ? @positionals_group.not_nil! : @optionals_group.not_nil!)
      group.arguments << argument
      unless option_strings.empty?
        option_strings.each { |name| @option_string_actions[name] = argument }
        if option_strings.any? { |name| NEGATIVE_NUMBER.matches?(name) }
          @has_negative_number_optionals = true
        end
      end
      argument
    end

    private ACTION_NAMES = %w[store store_const store_true store_false append append_const count help
      version extend boolean_optional parsers]
    private NARGS_NAMES = %w[? * + ... A...]

    private def has_prefix?(name : String) : Bool
      !name.empty? && @prefix_chars.includes?(name[0])
    end

    private def infer_optional_dest(names : Array(String)) : String
      long_names = names.select { |name| name.size > 1 && @prefix_chars.includes?(name[1]) }
      source = long_names.first? || names.first
      inferred = source.lstrip(@prefix_chars).gsub('-', '_')
      if inferred.empty?
        raise ConfigurationError.new("dest= is required for options like #{source.inspect}")
      end
      inferred
    end

    private def check_nargs(nargs : Int32 | String | Nil) : Nil
      case nargs
      when String
        unless NARGS_NAMES.includes?(nargs)
          raise ConfigurationError.new("invalid nargs value #{nargs.inspect}")
        end
      when Int32
        raise ConfigurationError.new("invalid nargs value #{nargs}") if nargs < 0
      end
    end

    private def check_action_kwargs(action : String, nargs : Int32 | String | Nil, const : Spec) : Nil
      case action
      when "store", "append", "extend"
        if nargs == 0
          raise ConfigurationError.new("nargs for #{action} actions must be != 0; if you have nothing to store, actions such as store true or store const may be more appropriate")
        end
        if !const.is_a?(Unset) && nargs != "?"
          raise ConfigurationError.new("nargs must be '?' to supply const")
        end
      when "parsers"
        if nargs != "A..."
          raise ConfigurationError.new("nargs must be 'A...' for action parsers")
        end
      else
        if !nargs.nil? && nargs != 0
          raise ConfigurationError.new("nargs must be 0 for action #{action}")
        end
      end
    end

    private def resolve_default(action : String, default : Spec,
                                positional : Bool, nargs : Int32 | String | Nil) : Spec
      return default unless default.is_a?(Unset)
      return @argument_default unless @argument_default.is_a?(Unset)
      return [] of Value if positional && nargs == "*"
      case action
      when "store_true"  then false
      when "store_false" then true
      else                    nil
      end
    end

    private def check_conflicts(argument : Argument) : Nil
      conflicting = argument.option_strings.compact_map do |name|
        existing = @option_string_actions[name]?
        existing ? {name, existing} : nil
      end
      return if conflicting.empty?

      if @conflict_handler == "resolve"
        conflicting.each do |name, existing|
          existing.option_strings.delete(name)
          @option_string_actions.delete(name)
          remove_action(existing) if existing.option_strings.empty?
        end
      else
        names = conflicting.map(&.first)
        message = names.size == 1 ? "conflicting option string: #{names.first}" :
          "conflicting option strings: #{names.join(", ")}"
        raise ConfigurationError.new(message)
      end
    end

    private def remove_action(action : Argument) : Nil
      @actions.delete(action)
      @argument_groups.each { |group| group.arguments.delete(action) }
      @groups.each { |group| group.arguments.delete(action) }
    end

    # Overload used when argument names are only known at runtime.
    def add_argument(names : Array(String), action : String | Nil = nil,
                     nargs : Int32 | String | Nil = nil,
                     const : Object? = UNSET, default : Object? = UNSET,
                     type : String | Symbol | Nil = nil,
                     choices : Object? = nil,
                     required : Bool | Nil = nil,
                     help : String | Suppress | Nil = nil,
                     metavar : String | Nil = nil,
                     dest : String | Nil = nil,
                     version : String | Nil = nil) : Argument
      add_argument_impl(names, action, nargs, const, default, type,
        choices, required, help, metavar, dest, version, nil, nil)
    end

    # Adds a named group of arguments.  Groups are rendered as their own help
    # sections, in the order they were created.
    def add_argument_group(title : String | Suppress | Nil = nil,
                           description : String | Suppress | Nil = nil) : ArgumentGroup
      group = ArgumentGroup.new(self, title, description)
      @argument_groups << group
      group
    end

    # Adds an action from a parent parser to this parser, preserving the
    # parent's group layout and optionally its mutually exclusive membership.
    private def add_parent(parent : ArgumentParser) : Nil
      unless parent.is_a?(ArgumentParser)
        raise ConfigurationError.new("parents must be a list of ArgumentParser")
      end

      targets = {} of ArgumentGroup => ArgumentGroup
      parent.@argument_groups.each do |parent_group|
        target = @argument_groups.find { |group| group.title == parent_group.title }
        unless target
          target = ArgumentGroup.new(self, parent_group.title, parent_group.description)
          @argument_groups << target
        end
        targets[parent_group] = target
      end

      parent.@actions.each do |argument|
        source = parent.@argument_groups.find { |group| group.arguments.includes?(argument) }
        target = source ? targets[source] : @optionals_group.not_nil!
        add_existing_argument(argument, target)
      end

      parent.@groups.each do |parent_group|
        container = if source = parent_group.container
                      @argument_groups.find { |group| group.title == source.title }
                    end
        mutex = MutuallyExclusiveGroup.new(self, parent_group.required?, container)
        parent_group.arguments.each do |argument|
          mutex.arguments << argument if @actions.includes?(argument)
        end
        @groups << mutex
      end

      parent.@parser_defaults.each do |dest, default|
        @parser_defaults[dest] = default
      end
    end

    private def add_existing_argument(argument : Argument,
                                      target_group : ArgumentGroup) : Nil
      check_conflicts(argument)
      @actions << argument
      target_group.arguments << argument
      argument.option_strings.each do |name|
        @option_string_actions[name] = argument
        if NEGATIVE_NUMBER.matches?(name)
          @has_negative_number_optionals = true
        end
      end
    end

    # Adds the subcommand positional.  The returned object creates and stores
    # the child parsers, and can be configured further through `add_parser`.
    def add_subparsers(required : Bool = false,
                       dest : String | Suppress | Nil = SUPPRESS,
                       help : String | Suppress | Nil = nil,
                       metavar : String | Nil = nil,
                       title : String | Suppress | Nil = nil,
                       description : String | Suppress | Nil = nil,
                       prog : String? = nil,
                       parser_class : ArgumentParser.class = ArgumentParser) : SubparsersAction
      if @subparsers_action
        raise ConfigurationError.new("cannot have multiple subparser arguments")
      end

      target_group = if title || description
                       add_argument_group(title || "subcommands", description)
                     else
                       @positionals_group.not_nil!
                     end
      dest_name = dest.is_a?(String) ? dest : "__subparsers__"
      computed_prog = prog || begin
        positionals = @actions.select { |argument| !argument.option? && !argument.help.is_a?(Suppress) }
        parts, _ = usage_parts(positionals)
        ([@prog] + parts).join(' ')
      end

      argument = add_argument_impl([dest_name], "parsers", "A...", UNSET, UNSET,
        nil, nil, required, help, metavar, nil, nil, nil, target_group)
      argument.dest_suppressed = dest.is_a?(Suppress) || dest.nil?
      action = SubparsersAction.new(self, argument, computed_prog, parser_class)
      argument.subparsers = action
      @subparsers_action = action
      action
    end

    # Sets defaults for destinations that are not otherwise defined, and
    # overrides the default of arguments that already exist (like
    # `argparse.ArgumentParser.set_defaults`).
    def set_defaults(**defaults) : Nil
      defaults.each do |key, value|
        @parser_defaults[key.to_s] = Argparse.normalize(value)
      end
      @actions.each do |action|
        value = defaults[action.dest]?
        action.default = Argparse.normalize(value) unless value.nil? && !defaults.has_key?(action.dest)
      end
    end

    # Returns the default for *dest*, or nil, like `argparse.get_default`.
    def get_default(dest : String) : Spec
      @actions.each do |action|
        default = action.default
        next if action.dest != dest
        next if default.is_a?(Unset) || default.is_a?(Suppress) || default.nil?
        return default
      end
      @parser_defaults[dest]? || UNSET
    end

    def add_mutually_exclusive_group(required : Bool = false,
                                     container : ArgumentGroup? = nil) : MutuallyExclusiveGroup
      group = MutuallyExclusiveGroup.new(self, required, container)
      @groups << group
      group
    end

    # ---------------------------------------------------------------
    # Parsing
    # ---------------------------------------------------------------

    def parse_args(args : Enumerable(String) = ARGV,
                   namespace : Namespace? = nil) : Namespace
      result, extras = parse_known_args(args, namespace)
      unless extras.empty?
        message = "unrecognized arguments: #{extras.join(' ')}"
        if @exit_on_error
          error(message)
        else
          raise ArgumentError.new(message)
        end
      end
      result
    end

    def parse(args : Enumerable(String) = ARGV,
              namespace : Namespace? = nil) : Namespace
      parse_args(args, namespace)
    end

    def parse_known_args(args : Enumerable(String) = ARGV,
                         namespace : Namespace? = nil) : Tuple(Namespace, Array(String))
      parse_known_args_mode(args, namespace, false)
    end

    def parse_intermixed_args(args : Enumerable(String) = ARGV,
                              namespace : Namespace? = nil) : Namespace
      result, extras = parse_known_intermixed_args(args, namespace)
      unless extras.empty?
        message = "unrecognized arguments: #{extras.join(' ')}"
        if @exit_on_error
          error(message)
        else
          raise ArgumentError.new(message)
        end
      end
      result
    end

    def parse_known_intermixed_args(args : Enumerable(String) = ARGV,
                                    namespace : Namespace? = nil) : Tuple(Namespace, Array(String))
      incompatible = @actions.find do |action|
        !action.option? && (action.nargs == "A..." || action.nargs == "...")
      end
      if incompatible
        raise ConfigurationError.new("parse_intermixed_args: positional arg with nargs=#{incompatible.nargs}")
      end
      parse_known_args_mode(args, namespace, true)
    end

    private def parse_known_args_mode(args : Enumerable(String),
                                      namespace : Namespace?,
                                      intermixed : Bool) : Tuple(Namespace, Array(String))
      namespace ||= Namespace.new
      @actions.each do |argument|
        next if argument.dest_suppressed
        next if namespace.has_key?(argument.dest)
        default = argument.default
        next if default.is_a?(Suppress) || default.is_a?(Unset)
        namespace[argument.dest] = clone_value(default)
      end
      @parser_defaults.each do |dest, default|
        next if namespace.has_key?(dest)
        next if default.is_a?(Suppress) || default.is_a?(Unset)
        namespace[dest] = clone_value(default)
      end
      begin
        extras = parse_known_args_impl(args.to_a, namespace, intermixed)
      rescue ex : ArgumentError
        raise ex unless @exit_on_error
        error(ex.message || "")
      end
      {namespace, extras}
    end

    # Prints usage to stderr and exits with status 2, like CPython.
    def error(message : String) : NoReturn
      STDERR << format_usage
      STDERR.puts "#{@prog}: error: #{message}"
      exit(2)
    end

    # Reads arguments from files named by `fromfile_prefix_chars`.  Each line
    # is passed through `convert_arg_line_to_args`, which subclasses can
    # override to split or transform lines.
    private def read_args_from_files(arg_strings : Array(String)) : Array(String)
      chars = @fromfile_prefix_chars
      return arg_strings unless chars
      result = [] of String
      arg_strings.each do |arg_string|
        if arg_string.empty? || !chars.includes?(arg_string[0])
          result << arg_string
          next
        end
        begin
          path = arg_string[1..]
          file_args = [] of String
          File.read(path).lines.each do |line|
            file_args.concat(convert_arg_line_to_args(line))
          end
          result.concat(read_args_from_files(file_args))
        rescue ex
          raise ArgumentError.new(ex.message || "cannot read arguments from #{arg_string.inspect}")
        end
      end
      result
    end

    # Converts one line from a fromfile argument file.  The default returns
    # the line unchanged, like CPython.
    def convert_arg_line_to_args(arg_line : String) : Array(String)
      [arg_line]
    end

    private def parse_known_args_impl(arg_strings : Array(String), namespace : Namespace,
                                      intermixed : Bool = false) : Array(String)
      if @fromfile_prefix_chars
        arg_strings = read_args_from_files(arg_strings)
      end
      pattern, option_string_indices = classify(arg_strings)
      run = ParseRun.new(namespace, @actions)

      max_option_string_index = option_string_indices.keys.max? || -1
      start_index = 0
      while start_index <= max_option_string_index
        next_option_string_index = start_index
        while next_option_string_index <= max_option_string_index
          break if option_string_indices.has_key?(next_option_string_index)
          next_option_string_index += 1
        end

        if !intermixed && start_index != next_option_string_index
          positionals_end_index = consume_positionals(run, arg_strings, pattern, start_index)
          if positionals_end_index > start_index
            start_index = positionals_end_index
            next
          end
          start_index = positionals_end_index
        end

        unless option_string_indices.has_key?(start_index)
          extras_index = start_index
          while extras_index < next_option_string_index && extras_index < arg_strings.size
            run.extras << arg_strings[extras_index]
            run.extras_pattern << pattern[extras_index]
            extras_index += 1
          end
          start_index = next_option_string_index
        end

        start_index = consume_optional(run, arg_strings, pattern, option_string_indices, start_index)
      end

      if !intermixed
        stop_index = consume_positionals(run, arg_strings, pattern, start_index)
        while stop_index < arg_strings.size
          run.extras << arg_strings[stop_index]
          run.extras_pattern << pattern[stop_index]
          stop_index += 1
        end
      else
        if start_index < arg_strings.size
          (start_index...arg_strings.size).each do |index|
            run.extras << arg_strings[index]
            run.extras_pattern << pattern[index]
          end
        end
        extras = run.extras.dup
        extras_pattern = run.extras_pattern.dup
        run.extras.clear
        run.extras_pattern.clear
        filtered_args = [] of String
        filtered_pattern = String::Builder.new
        extras.each_with_index do |value, index|
          next if extras_pattern[index] == 'O'
          filtered_args << value
          filtered_pattern << extras_pattern[index]
        end
        consumed = consume_positionals(run, filtered_args, filtered_pattern.to_s, 0)
        remaining = consumed
        extras.each_with_index do |value, index|
          if extras_pattern[index] == 'O'
            run.extras << value
          elsif remaining > 0
            remaining -= 1
          else
            run.extras << value
          end
        end
      end

      check_required(run)
      run.extras
    end

    # Classifies argv into a pattern of "O" (option), "A" (argument) and
    # "-" (bare `--`) characters, remembering how each option was spelled.
    private def classify(arg_strings : Array(String)) : Tuple(String, Hash(Int32, Array(OptionTuple)))
      builder = String::Builder.new
      option_string_indices = {} of Int32 => Array(OptionTuple)
      index = 0
      while index < arg_strings.size
        arg_string = arg_strings[index]
        if arg_string == "--"
          builder << '-'
          index += 1
          while index < arg_strings.size
            builder << 'A'
            index += 1
          end
          break
        end
        if tuples = parse_optional(arg_string)
          option_string_indices[index] = tuples
          builder << 'O'
        else
          builder << 'A'
        end
        index += 1
      end
      {builder.to_s, option_string_indices}
    end

    private def parse_optional(arg_string : String) : Array(OptionTuple)?
      return nil if arg_string.empty?
      return nil unless @prefix_chars.includes?(arg_string[0])

      if argument = @option_string_actions[arg_string]?
        return [OptionTuple.new(argument, arg_string, nil, nil)]
      end

      return nil if arg_string.size == 1

      option_string, separator, explicit_arg = arg_string.partition('=')
      unless separator.empty?
        if argument = @option_string_actions[option_string]?
          return [OptionTuple.new(argument, option_string, separator, explicit_arg)]
        end
      end

      tuples = get_option_tuples(arg_string)
      return tuples unless tuples.empty?

      if NEGATIVE_NUMBER.matches?(arg_string) && !@has_negative_number_optionals
        return nil
      end

      return nil if arg_string.includes?(' ')

      # Looks like an option, but this parser does not define it.
      [OptionTuple.new(nil, arg_string, nil, nil)]
    end

    private def get_option_tuples(option_string : String) : Array(OptionTuple)
      result = [] of OptionTuple
      chars = @prefix_chars

      if option_string.size > 1 && chars.includes?(option_string[0]) && chars.includes?(option_string[1])
        return result unless @allow_abbrev
        prefix, separator, explicit_arg = option_string.partition('=')
        if separator.empty?
          separator = ""
          explicit_arg = ""
        end
        @option_string_actions.each do |candidate, argument|
          next unless candidate.starts_with?(prefix)
          result << OptionTuple.new(argument, candidate,
            separator.empty? ? nil : separator,
            separator.empty? ? nil : explicit_arg)
        end
      elsif chars.includes?(option_string[0])
        prefix, separator, explicit_arg = option_string.partition('=')
        if separator.empty?
          separator = ""
          explicit_arg = ""
        end
        short_prefix = option_string[0, 2]
        short_explicit = option_string[2..]
        @option_string_actions.each do |candidate, argument|
          if candidate == short_prefix
            result << OptionTuple.new(argument, candidate, "", short_explicit)
          elsif @allow_abbrev && candidate.starts_with?(prefix)
            result << OptionTuple.new(argument, candidate,
              separator.empty? ? nil : separator,
              separator.empty? ? nil : explicit_arg)
          end
        end
      end
      result
    end

    private def consume_optional(run : ParseRun, arg_strings : Array(String),
                                 pattern : String,
                                 option_string_indices : Hash(Int32, Array(OptionTuple)),
                                 start_index : Int32) : Int32
      tuples = option_string_indices[start_index]
      if tuples.size > 1
        matches = tuples.map(&.option_string).join(", ")
        raise ArgumentError.new("ambiguous option: #{arg_strings[start_index]} could match #{matches}")
      end

      option_tuple = tuples.first
      action = option_tuple.action
      option_string = option_tuple.option_string
      sep = option_tuple.sep
      explicit_arg = option_tuple.explicit_arg

      action_tuples = [] of Tuple(Argument, Array(String), String)
      stop = start_index + 1

      while true
        current = action
        if current.nil?
          run.extras << arg_strings[start_index]
          run.extras_pattern << 'O'
          return start_index + 1
        end

        matched_explicit = explicit_arg
        if matched_explicit
          arg_count = match_argument(current, "A")
          single_dash = option_string.size > 1 && !@prefix_chars.includes?(option_string[1])

          if arg_count == 0 && single_dash && !matched_explicit.empty?
            if (sep && !sep.empty?) || @prefix_chars.includes?(matched_explicit[0])
              raise ArgumentError.new("ignored explicit argument #{Argparse.py_repr(matched_explicit)}", current.name)
            end
            action_tuples << {current, [] of String, option_string}
            char = option_string[0]
            option_string = "#{char}#{matched_explicit[0]}"
            if next_action = @option_string_actions[option_string]?
              action = next_action
              explicit_arg = matched_explicit[1..]
              if explicit_arg.empty?
                sep = nil
                explicit_arg = nil
              elsif explicit_arg[0] == '='
                sep = "="
                explicit_arg = explicit_arg[1..]
              else
                sep = ""
              end
            else
              run.extras << "#{char}#{matched_explicit}"
              run.extras_pattern << 'O'
              return start_index + 1
            end
          elsif arg_count == 1
            stop = start_index + 1
            action_tuples << {current, [matched_explicit], option_string}
            break
          else
            raise ArgumentError.new("ignored explicit argument #{Argparse.py_repr(matched_explicit)}", current.name)
          end
        else
          start = start_index + 1
          remaining = start < pattern.size ? pattern[start..] : ""
          arg_count = match_argument(current, remaining)
          stop = start + arg_count
          args = arg_strings[start, arg_count] || [] of String
          action_tuples << {current, args, option_string}
          break
        end
      end

      action_tuples.each do |taken, args, used_option_string|
        take_action(run, taken, args, used_option_string)
      end
      stop
    end

    private def consume_positionals(run : ParseRun, arg_strings : Array(String),
                                    pattern : String, start_index : Int32) : Int32
      positionals = run.positionals
      selected_pattern = start_index < pattern.size ? pattern[start_index..] : ""
      arg_counts = match_arguments_partial(positionals, selected_pattern)

      matched = positionals[0, arg_counts.size]
      arg_counts.each_with_index do |arg_count, index|
        action = matched[index]
        args = arg_strings[start_index, arg_count] || [] of String
        if action.nargs != "..."
          if (dash = pattern.index('-', start_index)) && dash < start_index + arg_count
            # CPython removes a single "--" marker from the matched arguments.
            if position = args.index("--")
              args = args.dup
              args.delete_at(position)
            end
          end
        end
        start_index += arg_count
        take_action(run, action, args, nil)
      end

      run.positionals = positionals[arg_counts.size..]? || [] of Argument
      start_index
    end

    private def match_argument(action : Argument, pattern : String) : Int32
      regex = Regex.new("\\A#{nargs_pattern(action)}")
      match = regex.match(pattern)
      if match.nil?
        message = case action.nargs
                  when nil then "expected one argument"
                  when "?" then "expected at most one argument"
                  when "+" then "expected at least one argument"
                  when Int32
                    count = action.nargs.as(Int32)
                    count == 1 ? "expected 1 argument" : "expected #{count} arguments"
                  else "unexpected arguments"
                  end
        raise ArgumentError.new(message, action.name)
      end
      match[1].to_s.size
    end

    private def match_arguments_partial(actions : Array(Argument), pattern : String) : Array(Int32)
      actions.size.downto(1) do |count|
        slice = actions[0, count]
        regex = Regex.new("\\A#{slice.map { |action| nargs_pattern(action) }.join}")
        match = regex.match(pattern)
        next if match.nil?
        result = (1...match.size).map { |index| match[index].to_s.size }
        if match.end < pattern.size && pattern[match.end] == 'O'
          while !result.empty? && result.last.zero?
            result.pop
          end
        end
        return result
      end
      [] of Int32
    end

    private def nargs_pattern(action : Argument) : String
      option = action.option?
      case nargs = action.nargs
      when nil
        option ? "([A])" : "(-*A-*)"
      when "?"
        option ? "(A?)" : "(-*A?-*)"
      when "*"
        option ? "(A*)" : "(-*[A-]*)"
      when "+"
        option ? "(A+)" : "(-*A[A-]*)"
      when "..."
        option ? "([AO]*)" : "(.*)"
      when "A..."
        option ? "(A[AO]*)" : "(-*A[-AO]*)"
      else
        count = nargs.as(Int32)
        option ? "([AO]{#{count}})" : "((?:-*A){#{count}}-*)"
      end
    end

    private def take_action(run : ParseRun, action : Argument,
                            arg_strings : Array(String),
                            option_string : String?) : Nil
      run.seen_actions << action
      values = get_values(action, arg_strings)

      if action.option? || !arg_strings.empty?
        run.seen_non_default << action
        if conflict = conflicting_action(run, action)
          raise ArgumentError.new("not allowed with argument #{conflict.name}", action.name)
        end
      end

      return if values.is_a?(Suppress)
      perform(run, action, values, option_string)
    end

    private def conflicting_action(run : ParseRun, action : Argument) : Argument?
      @groups.each do |group|
        next unless group.arguments.includes?(action)
        other = group.arguments.find do |candidate|
          !candidate.same?(action) && run.seen_non_default.includes?(candidate)
        end
        return other if other
      end
      nil
    end

    # Mirrors `argparse.ArgumentParser._get_values`.
    private def get_values(action : Argument, arg_strings : Array(String)) : Spec
      optional = action.option?
      if arg_strings.empty? && action.nargs == "?"
        value = optional ? action.const : action.default
        if value.is_a?(String)
          value = action.convert(value)
        end
        value
      elsif arg_strings.empty? && action.nargs == "*" && !optional
        if action.default.is_a?(Suppress)
          action.default
        elsif action.default.nil?
          [] of Value
        else
          action.default
        end
      elsif arg_strings.size == 1 && (action.nargs.nil? || action.nargs == "?")
        value = action.convert(arg_strings.first)
        check_value(action, value)
        value
      elsif action.nargs == "..."
        convert_all(action, arg_strings)
      else
        values = convert_all(action, arg_strings)
        values.each { |value| check_value(action, value) }
        values
      end
    end

    private def convert_all(action : Argument, arg_strings : Array(String)) : Array(Value)
      values = Array(Value).new
      arg_strings.each { |item| values << action.convert(item) }
      values
    end

    private def check_value(action : Argument, value : Value) : Nil
      choices = action.choices
      return if choices.nil?
      return if choices.any? { |choice| choice == value }
      rendered = choices.map { |choice| Argparse.py_repr(choice.to_s) }.join(", ")
      raise ArgumentError.new("invalid choice: #{Argparse.py_repr(value.to_s)} (choose from #{rendered})", action.name)
    end

    # Mirrors `__call__` of CPython's action classes.
    private def perform(run : ParseRun, action : Argument, values : Spec,
                        option_string : String?) : Nil
      namespace = run.namespace
      case action.action
      when "store"
        namespace[action.dest] = unwrap(values)
      when "store_const", "store_true", "store_false"
        namespace[action.dest] = unwrap(action.const)
      when "boolean_optional"
        namespace[action.dest] = !(option_string || "").starts_with?("--no-")
      when "append", "append_const"
        items = copy_items(namespace[action.dest]?)
        items << unwrap(action.action == "append" ? values : action.const)
        namespace[action.dest] = items
      when "extend"
        items = copy_items(namespace[action.dest]?)
        extend_items(items, unwrap(values))
        namespace[action.dest] = items
      when "count"
        count = namespace[action.dest]?
        namespace[action.dest] = (count.is_a?(Int64) ? count : 0_i64) + 1_i64
      when "help"
        puts format_help
        exit(0)
      when "version"
        puts action.version
        exit(0)
      when "parsers"
        subparsers = action.subparsers.not_nil!
        items = values.as(Array(Value))
        parser_name = items.first.as(String)
        remaining = items[1..].map(&.as(String))
        namespace[action.dest] = parser_name unless action.dest_suppressed
        subparser = subparsers.name_parser_map[parser_name]?
        unless subparser
          choices = subparsers.name_parser_map.keys.join(", ")
          raise ArgumentError.new("unknown parser #{Argparse.py_repr(parser_name)} (choices: #{choices})", action.name)
        end
        if subparsers.deprecated_names.includes?(parser_name)
          STDERR.puts "#{@prog}: warning: command '#{parser_name}' is deprecated"
        end
        subnamespace, subextras = subparser.parse_known_args(remaining)
        subnamespace.values.each { |key, value| namespace[key] = value }
        run.extras.concat(subextras)
      end
    end

    # `extend` appends every element of the parsed values, matching CPython's
    # `_ExtendAction`; a plain string is spread into its characters like a
    # Python string would be.
    private def extend_items(items : Array(Value), values : Value) : Nil
      case values
      when Array(Value) then values.each { |item| items << item }
      when String       then values.each_char { |character| items << character.to_s }
      when Nil          then nil
      else                   items << values
      end
    end

    private def unwrap(value : Spec) : Value
      case value
      when Suppress then nil
      when Unset    then nil
      else               value
      end
    end

    private def copy_items(items : Value) : Array(Value)
      copy = Array(Value).new
      case items
      when Array(Value) then items.each { |item| copy << item }
      when Nil          then nil
      else                   copy << items
      end
      copy
    end

    private def clone_value(value : Spec) : Value
      case value
      when Array(Value)
        copy = Array(Value).new
        value.each { |item| copy << clone_value(item) }
        copy
      else
        unwrap(value)
      end
    end

    private def check_required(run : ParseRun) : Nil
      required_actions = [] of String
      @actions.each do |action|
        next if run.seen_actions.includes?(action)
        if action.required
          required_actions << action.name
        else
          default = action.default
          if !action.dest_suppressed && default.is_a?(String) && run.namespace.has_key?(action.dest)
            # CPython converts string defaults that were never overridden.
            run.namespace[action.dest] = action.convert(default)
          end
        end
      end
      unless required_actions.empty?
        raise ArgumentError.new("the following arguments are required: #{required_actions.join(", ")}")
      end

      @groups.each do |group|
        next unless group.required?
        next if group.arguments.any? { |action| run.seen_non_default.includes?(action) }
        names = group.arguments.map(&.name).join(' ')
        raise ArgumentError.new("one of the arguments #{names} is required")
      end
    end

    # ---------------------------------------------------------------
    # Help formatting
    # ---------------------------------------------------------------

    MAX_HELP_POSITION = 24
    INDENT            =  2

    # `usage: ...` followed by a blank line, like Python's internal
    # `_format_usage`.
    def format_usage : String
      block = usage_block
      return "" if block.empty?
      block.rstrip('\n') + "\n"
    end

    def print_usage(io : IO = STDERR) : Nil
      io << format_usage
    end

    def format_help : String
      buffer = String.build do |io|
        io << usage_block
        if text = @description
          io << expand_text(text) << "\n\n"
        end
        column = help_column
        @argument_groups.each { |group| write_group(io, group, column) }
        if text = @epilog
          io << expand_text(text) << "\n\n"
        end
      end
      buffer.rstrip('\n') + "\n"
    end

    def print_help(io : IO = STDOUT) : Nil
      io << format_help
    end

    def to_s(io : IO) : Nil
      io << format_help
    end

    private def usage_block : String
      return "" if @usage.is_a?(Suppress)
      String.build do |io|
        io << "usage: "
        case declared = @usage
        when String
          io << expand_text(declared)
        else
          io << usage_layout
        end
        io << "\n\n"
      end
    end

    private def usage_layout : String
      actions = @actions.reject { |argument| argument.help.is_a?(Suppress) }
      return @prog if actions.empty?

      parts, positionals_start = usage_parts(actions)
      usage = ([@prog] + parts).join(' ')
      prefix = "usage: "
      return usage if prefix.size + usage.size <= @width

      optionals = parts[0, positionals_start]
      positionals = parts[positionals_start..]? || [] of String
      lines = [] of String
      if prefix.size + @prog.size <= 0.75 * @width
        indent = " " * (prefix.size + @prog.size + 1)
        if !optionals.empty?
          lines = wrap_usage_parts([@prog] + optionals, indent, prefix)
          lines.concat(wrap_usage_parts(positionals, indent, nil))
        elsif !positionals.empty?
          lines = wrap_usage_parts([@prog] + positionals, indent, prefix)
        else
          lines = [@prog]
        end
      else
        indent = " " * prefix.size
        combined = wrap_usage_parts(optionals + positionals, indent, nil)
        if combined.size > 1
          lines = wrap_usage_parts(optionals, indent, nil)
          lines.concat(wrap_usage_parts(positionals, indent, nil))
        else
          lines = combined
        end
        lines = [@prog] + lines
      end
      lines.join('\n')
    end

    private def wrap_usage_parts(parts : Array(String), indent : String,
                                 first_prefix : String?) : Array(String)
      lines = [] of String
      line = [] of String
      indent_length = indent.size
      line_length = first_prefix ? first_prefix.size - 1 : indent_length - 1
      parts.each do |part|
        if line_length + 1 + part.size > @width && !line.empty?
          lines << indent + line.join(' ')
          line = [] of String
          line_length = indent_length - 1
        end
        line << part
        line_length += part.size + 1
      end
      lines << indent + line.join(' ') unless line.empty?
      if first_prefix && !lines.empty? && lines.first.size >= indent_length
        lines[0] = lines.first[indent_length, lines.first.size - indent_length]
      end
      lines
    end

    # Port of `argparse.HelpFormatter._get_actions_usage_parts`.
    private def usage_parts(actions : Array(Argument)) : Tuple(Array(String), Int32)
      groups = {} of Argument => MutuallyExclusiveGroup
      @groups.each do |group|
        group.arguments.each { |argument| groups[argument] = group if actions.includes?(argument) }
      end

      optionals = [] of Tuple(Bool, Array(Argument))
      positionals = [] of Tuple(Bool, Array(Argument))
      emitted = Set(Argument).new

      actions.each do |action|
        next if emitted.includes?(action)
        next unless action.option?
        if group = groups[action]?
          members = [action]
          group.arguments.each do |candidate|
            next unless candidate.option?
            next if candidate.same?(action)
            next if emitted.includes?(candidate)
            next unless groups[candidate]?.try(&.same?(group))
            members << candidate
          end
          members.each { |member| emitted << member }
          optionals << {group.required?, members}
        else
          emitted << action
          optionals << {false, [action]}
        end
      end

      actions.each do |action|
        next if emitted.includes?(action)
        next if action.option?
        if group = groups[action]?
          members = [] of Argument
          group.arguments.each do |candidate|
            next unless candidate.option?
            next if emitted.includes?(candidate)
            next unless groups[candidate]?.try(&.same?(group))
            members << candidate
          end
          members << action
          members.each { |member| emitted << member }
          positionals << {group.required?, members}
        else
          emitted << action
          positionals << {false, [action]}
        end
      end

      parts = [] of String
      positionals_start = 0
      entries = optionals + positionals
      entries.each_with_index do |(required, members), entry_index|
        positionals_start = parts.size if entry_index == optionals.size
        in_group = members.size > 1
        start = parts.size
        members.each do |argument|
          part = if argument.option?
                   if argument.nargs == 0
                     argument.option_strings.first
                   else
                     "#{argument.option_strings.first} #{args_usage(argument)}"
                   end
                 else
                   args_usage(argument)
                 end
          if in_group && !argument.option?
            if part.starts_with?('[') && part.ends_with?(']') && part.size > 1
              part = part[1, part.size - 2]
            end
          end
          if argument.option?
            part = "[#{part}]" unless argument.required || required || in_group
          end
          parts << part
        end
        next unless in_group
        parts[start] = (required ? "(" : "[") + parts[start]
        (start...(parts.size - 1)).each { |index| parts[index] += " |" }
        parts[parts.size - 1] += required ? ")" : "]"
      end
      {parts, positionals_start}
    end

    private def args_usage(argument : Argument) : String
      metavar = metavar_for(argument)
      case nargs = argument.nargs
      when nil   then metavar
      when "?"   then "[#{metavar}]"
      when "*"   then "[#{metavar} ...]"
      when "+"   then "#{metavar} [#{metavar} ...]"
      when "..." then "..."
      when "A..." then "#{metavar} ..."
      else            Array.new(nargs.as(Int32), metavar).join(' ')
      end
    end

    private def metavar_for(argument : Argument) : String
      if metavar = argument.metavar
        return metavar
      end
      if subparsers = argument.subparsers
        return "{#{subparsers.choices_names.join(',')}}"
      end
      if choices = argument.choices
        return "{#{choices.map { |choice| Argparse.py_str(choice) }.join(',')}}"
      end
      argument.option? ? argument.dest.upcase : argument.dest
    end

    private def help_column : Int32
      longest = 0
      @actions.each do |argument|
        next if argument.help.is_a?(Suppress)
        size = invocation(argument).size + INDENT
        longest = size if size > longest
      end
      max_help_position = Math.min(MAX_HELP_POSITION, Math.max(@width - 20, INDENT * 2))
      Math.min(longest + INDENT, max_help_position)
    end

    private def invocation(argument : Argument) : String
      return metavar_for(argument) unless argument.option?
      names = argument.option_strings.join(", ")
      return names if argument.nargs == 0
      "#{names} #{args_usage(argument)}"
    end

    private def write_group(io : IO, group : ArgumentGroup, column : Int32) : Nil
      visible = group.arguments.reject { |argument| argument.help.is_a?(Suppress) }
      return if visible.empty?
      title = group.title
      if title && !title.is_a?(Suppress)
        io << title << ":\n"
      end
      description = group.description
      if description && !description.is_a?(Suppress)
        io << " " * INDENT << expand_text(description) << "\n\n"
      end
      write_actions(io, visible, column)
    end

    private def write_actions(io : IO, arguments : Array(Argument),
                              column : Int32) : Nil
      arguments.each do |argument|
        write_action(io, argument, column, INDENT)
        if subparsers = argument.subparsers
          subparsers.choices_actions.each do |choice|
            write_action(io, choice, column, INDENT * 2)
          end
        end
      end
      io << '\n'
    end

    private def write_action(io : IO, argument : Argument, column : Int32,
                             indent : Int32) : Nil
      action_width = column - indent - 2
      help_width = Math.max(@width - column, 11)
      header = invocation(argument)
      io << " " * indent
      help_text = argument.help
      if help_text.nil? || help_text.is_a?(Suppress)
        io << header << '\n'
        return
      end

      if header.size <= action_width
        io << header << " " * (action_width - header.size + 2)
        first_line_column = 0
      else
        io << header << '\n'
        first_line_column = column
      end

      expanded = expand_help(argument, help_text)
      if expanded.strip.empty?
        io << '\n'
        return
      end
      lines = wrap_text(expanded, help_width)
      io << " " * first_line_column << lines.first << '\n'
      lines[1..].each { |line| io << " " * column << line << '\n' }
    end

    # Expands `%(prog)s` and friends in description/epilog/usage text.
    private def expand_text(text : String) : String
      text.gsub("%(prog)s", @prog).gsub("%%", "%")
    end

    private def expand_help(argument : Argument, template : String) : String
      result = String.build do |io|
        index = 0
        while index < template.size
          if template[index] == '%' && index + 1 < template.size
            following = template[index + 1]
            if following == '%'
              io << '%'
              index += 2
              next
            elsif following == '('
              if close = template.index(')', index)
                key = template[(index + 2)...close]
                if replacement = help_parameter(argument, key)
                  io << replacement
                  index = close + 1
                  index += 1 if index < template.size && template[index] == 's'
                  next
                end
              end
            end
          end
          io << template[index]
          index += 1
        end
      end
      result
    end

    private def help_parameter(argument : Argument, key : String) : String?
      case key
      when "prog"    then @prog
      when "dest"    then argument.dest
      when "type"    then argument.type_name
      when "metavar" then argument.metavar
      when "choices" then argument.choices.try { |choices| choices.map { |choice| Argparse.py_str(choice) }.join(", ") }
      when "const"   then argument.const.is_a?(Suppress) ? nil : Argparse.py_str(unwrap(argument.const))
      when "default" then argument.default.is_a?(Suppress) ? nil : Argparse.py_str(unwrap(argument.default))
      else                nil
      end
    end

    # Greedy word wrapping equivalent to `textwrap.wrap` for the help strings
    # this formatter produces.
    private def wrap_text(text : String, width : Int32) : Array(String)
      words = text.split(/\s+/).reject(&.empty?)
      return [""] if words.empty?
      lines = [] of String
      current = ""
      words.each do |word|
        if current.empty?
          current = word
        elsif current.size + 1 + word.size <= width
          current = "#{current} #{word}"
        else
          lines << current
          current = word
        end
        while current.size > width
          lines << current[0, width]
          current = current[width..]
        end
      end
      lines << current unless current.empty?
      lines
    end
  end
end

alias ArgumentParser = Argparse::ArgumentParser
alias ArgumentNamespace = Argparse::Namespace
alias ArgumentParserError = Argparse::ArgumentError
