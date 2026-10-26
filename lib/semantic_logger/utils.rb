require "json"

module SemanticLogger
  # Internal-use only utility functions for Semantic Logger.
  # Not intended for public use.
  module Utils
    def self.constantize_symbol(symbol, namespace = "SemanticLogger::Appender")
      klass = "#{namespace}::#{camelize(symbol.to_s)}"
      constant =
        begin
          Object.const_get(klass)
        rescue NameError
          raise(ArgumentError,
                "Could not convert symbol: #{symbol.inspect} to a class in: #{namespace}. Looking for: #{klass}")
        end

      # The resolved constant is instantiated by the caller, so ensure it is
      # actually a class within the expected namespace rather than some other
      # constant that happens to share the name.
      unless constant.is_a?(Class)
        raise(ArgumentError,
              "Could not convert symbol: #{symbol.inspect} to a class in: #{namespace}. #{klass} is not a class.")
      end

      constant
    end

    # Borrow from Rails, when not running Rails
    def self.camelize(term)
      string = term.to_s
      string = string.sub(/^[a-z\d]*/, &:capitalize)
      string.gsub!(%r{(?:_|(/))([a-z\d]*)}i) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).capitalize}" }
      string.gsub!("/".freeze, "::".freeze)
      string
    end

    # Returns the visibility for an instance method
    def self.method_visibility(mod, method_name)
      method_name = method_name.to_sym
      if mod.instance_methods.include?(method_name)
        :public
      elsif mod.private_instance_methods.include?(method_name)
        :private
      elsif mod.protected_instance_methods.include?(method_name)
        :protected
      end
    end

    # Extract the backtrace stripping off the leading semantic logger entries.
    # Leaves all other system and gem path entries in place.
    # Returns a new Array, leaving the supplied stack unchanged since it can belong to the caller.
    def self.extract_backtrace(stack = caller)
      stack.drop_while { |path| extract_path?(path) }
    end

    def self.extract_paths
      @extract_paths ||= %w[lib/semantic_logger lib/rails_semantic_logger]
    end

    # Whether this path should be excluded from any cleansed backtrace
    def self.extract_path?(path)
      extract_paths.any? { |exclude| path.include?(exclude) }
    end

    # Try to strip everything off of the supplied backtrace, until the first application stack entry is at the top.
    # For example all leading gem paths and built-in ruby code paths are removed from the top.
    # Once the first application entry is found, the remaining stack is returned.
    def self.strip_backtrace(stack = caller)
      while (first = stack.first) && (strip_path?(first) || extract_path?(first))
        stack.shift
      end
      stack
    end

    # Paths to exclude in the stripped backtrace
    # Includes Gems and built-in Ruby code paths
    def self.strip_paths
      @strip_paths ||=
        begin
          paths = Gem.path | [Gem.default_dir]
          paths << RbConfig::CONFIG["rubylibdir"]
          paths
        end
    end

    # Whether this path should be excluded from any cleansed backtrace
    def self.strip_path?(path)
      strip_paths.any? { |exclude| path.start_with?(exclude) }
    end

    # Serializes the value to JSON, repairing the data only when necessary.
    #
    # Data that JSON cannot represent appears in well under 1% of log events, so it
    # is wasteful to walk and reallocate the entire structure (see .json_safe) on
    # every call. Instead this attempts `.to_json` directly and only falls back to a
    # repaired copy when serialization fails because of the data:
    # * Invalid UTF-8. Depending on the json gem version this raises
    #   Encoding::UndefinedConversionError (an EncodingError) or JSON::GeneratorError.
    # * Infinity and NaN, which raise JSON::GeneratorError.
    # * Structures nested deeper than the json gem allows, which raise
    #   JSON::NestingError (a JSON::ParserError, not a GeneratorError).
    # * A Struct or Data instance. The json gem writes one as the String returned by
    #   its #to_s, which for both is #inspect: every member is written with #inspect,
    #   exposing the instance variables of any object it holds, and without a depth
    #   limit, so a deep enough structure raises SystemStackError. The output is
    #   checked for that rendering (a JSON String starting with "#<struct " or
    #   "#<data "), and SystemStackError is rescued, so .json_safe can write the
    #   members as a JSON object instead. The json gem offers no hook for a Struct
    #   short of strict mode, which also rejects common values such as Time, and
    #   finding one up front would mean walking every payload on the hot path.
    #   ActiveSupport already writes both through #as_json, so its output never
    #   matches the check.
    #
    # Log data can come from untrusted input, for example a float parsed from a request
    # parameter or a deeply nested request body. Without the repair, such a value would
    # make the whole log event impossible to serialize, and so silently dropped.
    #
    # The retry is attempted only once: if it still fails (for example an object whose
    # own #to_json raises), the error propagates unchanged rather than being swallowed.
    def self.to_json(value)
      json =
        begin
          value.to_json
        rescue JSON::GeneratorError, JSON::NestingError, EncodingError, SystemStackError
          nil
        end
      # Almost no JSON holds a "<", and Ruby finds a single byte several times faster
      # than a longer substring, so look for it before calling .inspected_struct?.
      return json if json && !(json.include?("<".freeze) && inspected_struct?(json))

      json_safe(value).to_json
    end

    # How the json gem writes a Struct or a Data instance, through its #inspect.
    INSPECTED_STRUCT = "\"#<struct ".freeze
    INSPECTED_DATA   = "\"#<data ".freeze

    # Whether the JSON holds a Struct or Data instance written through its #inspect.
    #
    # A String that merely starts with the same text is also matched; repairing it
    # only costs time, since .json_safe leaves the String as it is.
    def self.inspected_struct?(json)
      json.include?(INSPECTED_STRUCT) || json.include?(INSPECTED_DATA)
    end
    private_class_method :inspected_struct?

    # Nesting depth after which .json_safe replaces a Hash, Array, Struct, or Data with a
    # placeholder. Well below the json gem's default max_nesting of 100, leaving room for
    # the levels that a formatter wraps the payload in.
    MAX_JSON_SAFE_DEPTH = 32

    # Returns a copy of the supplied value that JSON can represent:
    # * Every String is converted to valid UTF-8, as by .encode_utf8.
    # * Infinity and NaN floats become the Strings "Infinity", "-Infinity", and "NaN".
    # * A Struct or Data instance becomes a Hash of its members (from #to_h), as
    #   ActiveSupport's #as_json does, so that its members follow these same rules.
    # * A Hash, Array, Struct, or Data nested deeper than MAX_JSON_SAFE_DEPTH is replaced
    #   with a placeholder String naming its class, such as "#<Hash nested too deeply>".
    #   This also ends a self-referencing structure.
    # Any other value is returned as-is.
    #
    # The recursion never goes deeper than MAX_JSON_SAFE_DEPTH, and the placeholder does
    # not look inside the structure it replaces. Rendering it instead (for example with
    # #inspect) would recurse without limit through an arbitrarily deep structure,
    # raising SystemStackError (or crashing Ruby) on the appender's thread, and would
    # expose the instance variables of any object inside it.
    def self.json_safe(value, depth = 0)
      case value
      when String
        encode_utf8_string(value)
      when Float
        value.finite? ? value : value.to_s
      when Hash, Array, Struct, ::Data
        return "#<#{value.class} nested too deeply>" if depth >= MAX_JSON_SAFE_DEPTH

        json_safe_members(value, depth + 1)
      else
        value
      end
    end

    # Returns a copy of the elements of a Hash, Array, Struct, or Data, each made safe
    # by .json_safe at the supplied depth.
    def self.json_safe_members(value, depth)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), hash|
          hash[json_safe(key, depth)] = json_safe(val, depth)
        end
      when Array
        value.map { |element| json_safe(element, depth) }
      else
        # A Struct or Data. A #to_h that does not return a Hash is made safe one level
        # deeper, so that the recursion still ends.
        members = value.to_h
        members.is_a?(Hash) ? json_safe_members(members, depth) : json_safe(members, depth)
      end
    end
    private_class_method :json_safe_members

    # Returns a copy of the supplied value with every String converted to valid UTF-8.
    #
    # Recurses through Hash and Array structures, cleansing both keys and values.
    # Strings that are already valid UTF-8 are returned unchanged (the common case),
    # so the fast path allocates nothing. Any other value (Symbol, Numeric, Time, nil,
    # ...) is returned as-is.
    #
    # Used by .to_json on the rare failing path, and directly by formatters that
    # serialize per value or emit to a non-JSON sink (where a single `.to_json`
    # rescue boundary cannot catch an intermediate failure).
    def self.encode_utf8(value)
      case value
      when String
        encode_utf8_string(value)
      when Hash
        value.each_with_object({}) do |(key, val), hash|
          hash[encode_utf8(key)] = encode_utf8(val)
        end
      when Array
        value.map { |element| encode_utf8(element) }
      else
        value
      end
    end

    # Options used when transcoding a string to UTF-8.
    # Invalid byte sequences and characters that cannot be represented in UTF-8 are
    # dropped rather than substituted, matching the preference in issue #180.
    ENCODE_UTF8_OPTIONS = {invalid: :replace, undef: :replace, replace: "".freeze}.freeze

    # Returns the string converted to valid UTF-8, dropping any invalid bytes.
    def self.encode_utf8_string(string)
      return string if string.encoding == Encoding::UTF_8 && string.valid_encoding?

      if string.encoding == Encoding::UTF_8
        # Correctly tagged as UTF-8 but contains invalid byte sequences.
        string.scrub("")
      else
        # Different encoding (e.g. ASCII-8BIT / Latin-1): transcode into UTF-8.
        string.encode(Encoding::UTF_8, **ENCODE_UTF8_OPTIONS)
      end
    rescue EncodingError
      # Last resort for encodings without a converter to UTF-8: reinterpret the
      # raw bytes as UTF-8 and drop anything invalid. Logging must never raise.
      string.dup.force_encoding(Encoding::UTF_8).scrub("")
    end
  end
end
