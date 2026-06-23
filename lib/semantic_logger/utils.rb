require "json"

module SemanticLogger
  # Internal-use only utility functions for Semantic Logger.
  # Not intended for public use.
  module Utils
    def self.constantize_symbol(symbol, namespace = "SemanticLogger::Appender")
      klass = "#{namespace}::#{camelize(symbol.to_s)}"
      begin
        Object.const_get(klass)
      rescue NameError
        raise(ArgumentError,
              "Could not convert symbol: #{symbol.inspect} to a class in: #{namespace}. Looking for: #{klass}")
      end
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
    def self.extract_backtrace(stack = caller)
      while (first = stack.first) && extract_path?(first)
        stack.shift
      end
      stack
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

    # Serializes the value to JSON, repairing invalid UTF-8 only when necessary.
    #
    # Non UTF-8 data appears in well under 1% of log events, so it is wasteful to
    # walk and reallocate the entire structure (see .encode_utf8) on every call.
    # Instead this attempts `.to_json` directly and only falls back to cleansing
    # when serialization fails because of an encoding problem.
    #
    # The exception raised for non UTF-8 data depends on the json gem version:
    # older versions raise Encoding::UndefinedConversionError (an EncodingError),
    # newer versions wrap it as JSON::GeneratorError, so both are rescued. The
    # retry is attempted only once: if it still fails (for example a
    # JSON::GeneratorError caused by something other than encoding, such as NaN),
    # the error propagates unchanged rather than being swallowed.
    def self.to_json(value)
      value.to_json
    rescue JSON::GeneratorError, EncodingError
      encode_utf8(value).to_json
    end

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
