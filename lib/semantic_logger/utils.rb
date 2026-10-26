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
    # * A Struct, Data, Set, or OpenStruct instance. The json gem writes one as the String
    #   returned by its #to_s, which for each is #inspect: every member is written with
    #   #inspect, exposing the instance variables of any object it holds, and without a
    #   depth limit, so a deep enough structure raises SystemStackError. The output is
    #   checked for that rendering (a JSON String starting with "#<", or "Set[" for a Set on
    #   Ruby 4.0), and SystemStackError is rescued, so .json_safe can write the members as a JSON object
    #   or array instead. The json gem offers no hook for these short of strict mode,
    #   which also rejects common values such as Time, and finding one up front would mean
    #   walking every payload on the hot path. ActiveSupport already writes them through
    #   #as_json, and escapes "<", so its output never matches the check.
    #
    # Log data can come from untrusted input, for example a float parsed from a request
    # parameter or a deeply nested request body. Without the repair, such a value would
    # make the whole log event impossible to serialize, and so silently dropped.
    #
    # The retry is attempted only once: if it still fails (for example an object whose
    # own #to_json raises), the error propagates unchanged rather than being swallowed.
    def self.to_json(value)
      clean_json(value) || json_safe(value).to_json
    end

    # Returns the value when JSON writes it as it is, otherwise a .json_safe copy, for a writer
    # that serializes the value itself, such as GELF. The check costs one #to_json; only the
    # rare value that needs repairing is copied.
    def self.json_ready(value)
      clean_json(value) ? value : json_safe(value)
    end

    # Returns [String] the value's JSON, or nil when .to_json has to repair the data.
    def self.clean_json(value)
      json = value.to_json
      # Almost no JSON holds a "<", and Ruby finds one byte several times faster than a longer
      # substring, so it is looked for first. A String that merely starts with the same text is
      # also repaired; that only costs time, since .json_safe leaves such a String as it is.
      return if json.include?("<") && json.include?(INSPECTED_OBJECT)
      return if INSPECTED_SET && json.include?(INSPECTED_SET)

      json
    rescue JSON::GeneratorError, JSON::NestingError, EncodingError, SystemStackError
      nil
    end
    private_class_method :clean_json

    # How the json gem writes an object through its #to_s: a JSON String starting with "#<", as
    # for a Struct, Data, Set, or OpenStruct, whose #to_s is its #inspect.
    INSPECTED_OBJECT = "\"#<".freeze

    # How the json gem writes a Set where Set#inspect is "Set[...]" (Ruby 4.0), which holds no
    # "#<" unless the Set holds an object. Nil where Set#inspect starts with "#<" too.
    INSPECTED_SET = (::Set.new.inspect.start_with?("#<") ? nil : "\"Set[").freeze

    # Nesting depth after which .json_safe replaces a Hash, Array, Struct, or Data with a
    # placeholder. Well below the json gem's default max_nesting of 100, leaving room for
    # the levels that a formatter wraps the payload in.
    MAX_JSON_SAFE_DEPTH = 32

    # Returns [String] value#inspect, or what the block renders the value as (for example with
    # Amazing Print), without overflowing the stack for a value nested too deeply.
    #
    # #inspect has no depth limit: a Hash a few hundred levels deep overflows the stack of a
    # thread. Rescuing the SystemStackError is not enough, since on macOS a second such overflow
    # on the same thread crashes Ruby instead. A value that holds a structure nested deeper than
    # MAX_JSON_SAFE_DEPTH is therefore rendered from a .json_safe copy, as the JSON formatters
    # write it, cut off at that depth with their placeholder. Only that case pays for the copy.
    def self.safe_inspect(value)
      value = json_safe(value) if nested_too_deeply?(value)
      block_given? ? yield(value) : value.inspect
    end

    # Returns [true|false] whether the value holds a Hash, Array, Struct, or Data nested deeper
    # than MAX_JSON_SAFE_DEPTH, which .json_safe would replace with a placeholder. Never recurses
    # deeper than that itself, and follows the same rules as .json_safe.
    def self.nested_too_deeply?(value, depth = 0)
      case value
      when String, Symbol, Integer, NilClass
        # The most common values, ruled out before the slower checks below.
        false
      when Hash
        depth >= MAX_JSON_SAFE_DEPTH ||
          value.any? { |key, val| nested_too_deeply?(key, depth + 1) || nested_too_deeply?(val, depth + 1) }
      when Array, ::Set
        depth >= MAX_JSON_SAFE_DEPTH || value.any? { |element| nested_too_deeply?(element, depth + 1) }
      when Struct, ::Data
        members_nested_too_deeply?(value, depth)
      else
        open_struct?(value) && members_nested_too_deeply?(value, depth)
      end
    end

    # Whether the members of a Struct, Data, or OpenStruct are nested too deeply. As in
    # .json_safe_members, a #to_h that does not return a Hash is one level deeper.
    def self.members_nested_too_deeply?(value, depth)
      return true if depth >= MAX_JSON_SAFE_DEPTH

      members = value.to_h
      members.is_a?(Hash) ? nested_too_deeply?(members, depth) : nested_too_deeply?(members, depth + 1)
    end
    private_class_method :members_nested_too_deeply?

    # Returns [true|false] whether .json_safe writes the value as a JSON object or array: a Hash,
    # Array, Set, Struct, Data, or OpenStruct. Every one of them would otherwise be written by its
    # #to_s, which is its #inspect.
    def self.structure?(value)
      case value
      when Hash, Array, ::Set, Struct, ::Data
        true
      else
        open_struct?(value)
      end
    end

    # Whether the value is an OpenStruct. The ostruct gem is only loaded by the application, and
    # is a bundled gem since Ruby 4.0, so Semantic Logger never requires it.
    def self.open_struct?(value)
      # Only recognizes an OpenStruct, so that it is not written through its #inspect.
      defined?(::OpenStruct) && value.is_a?(::OpenStruct) # rubocop:disable Style/OpenStructUse
    end
    private_class_method :open_struct?

    # Returns a copy of the supplied value that JSON can represent:
    # * Every String is converted to valid UTF-8, as by .encode_utf8.
    # * Infinity and NaN floats become the Strings "Infinity", "-Infinity", and "NaN".
    # * A Struct, Data, or OpenStruct instance becomes a Hash of its members (from #to_h),
    #   and a Set an Array, as ActiveSupport's #as_json does, so that its members follow
    #   these same rules.
    # * A Hash key that is itself a structure becomes the JSON of its copy, since JSON writes a
    #   key with #to_s, which for a structure is its #inspect.
    # * Any other object whose JSON raises because of invalid UTF-8, such as an exception
    #   message or a Pathname built from an uploaded file name, becomes its #to_s converted to
    #   valid UTF-8.
    # * A Hash, Array, Set, Struct, or Data nested deeper than MAX_JSON_SAFE_DEPTH is replaced
    #   with a placeholder String naming its class, such as "#<Hash nested too deeply>".
    #   So is one that holds itself, at the point where it would repeat.
    # Any other value is returned as-is.
    #
    # The recursion never goes deeper than MAX_JSON_SAFE_DEPTH, and the placeholder does
    # not look inside the structure it replaces. Rendering it instead (for example with
    # #inspect) would recurse without limit through an arbitrarily deep structure,
    # raising SystemStackError (or crashing Ruby) on the appender's thread, and would
    # expose the instance variables of any object inside it. Ending a self-referencing
    # structure where it repeats, rather than at that depth, keeps one that holds itself
    # more than once from being copied an exponential number of times.
    def self.json_safe(value, depth = 0, ancestors = nil)
      case value
      when String
        encode_utf8_string(value)
      when Float
        value.finite? ? value : value.to_s
      when Symbol, Integer, NilClass, TrueClass, FalseClass
        value
      when Hash, Array, ::Set, Struct, ::Data
        json_safe_structure(value, depth, ancestors)
      else
        open_struct?(value) ? json_safe_structure(value, depth, ancestors) : json_safe_object(value)
      end
    end

    # Returns a copy of a Hash, Array, Set, Struct, Data, or OpenStruct, or the placeholder for
    # one nested too deeply or that holds itself.
    def self.json_safe_structure(value, depth, ancestors)
      ancestors ||= []
      if depth >= MAX_JSON_SAFE_DEPTH || ancestors.any? { |ancestor| ancestor.equal?(value) }
        return "#<#{value.class} nested too deeply>"
      end

      ancestors.push(value)
      begin
        json_safe_members(value, depth + 1, ancestors)
      ensure
        ancestors.pop
      end
    end
    private_class_method :json_safe_structure

    # Returns any other object as it is, when JSON can write it, otherwise its #to_s converted
    # to valid UTF-8.
    def self.json_safe_object(value)
      value.to_json
      value
    rescue JSON::GeneratorError, EncodingError
      encode_utf8_string(value.to_s)
    end
    private_class_method :json_safe_object

    # Returns a copy of the elements of a Hash, Array, Set, Struct, or Data, each made safe
    # by .json_safe at the supplied depth.
    def self.json_safe_members(value, depth, ancestors)
      case value
      when Hash
        value.each_with_object({}) do |(key, val), hash|
          key       = json_safe(key, depth, ancestors)
          key       = key.to_json if key.is_a?(Hash) || key.is_a?(Array)
          hash[key] = json_safe(val, depth, ancestors)
        end
      when Array, ::Set
        value.map { |element| json_safe(element, depth, ancestors) }
      else
        # A Struct, Data, or OpenStruct. A #to_h that does not return a Hash is made safe one
        # level deeper, so that the recursion still ends.
        members = value.to_h
        members.is_a?(Hash) ? json_safe_members(members, depth, ancestors) : json_safe(members, depth, ancestors)
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
