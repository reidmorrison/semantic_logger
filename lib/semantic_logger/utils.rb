require "json"
require "uri"
require "semantic_logger/core_ext/warning"

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

    # Returns [URI] the parsed url, supplied as the named option.
    #
    # Raises URI::InvalidURIError for an invalid url, including nil, as .without_url_in_errors does.
    def self.parse_url(url, option: ":url", hint: nil)
      without_url_in_errors(option: option, hint: hint) { URI.parse(url) }
    end

    # Returns the result of the block, which uses the url supplied as the named option, for example
    # to build a client gem's connection.
    #
    # Raises any of the errors from the block again, of the same class, without the url in its
    # message, or as its cause, since a url can hold a user and password, or a token in its path or
    # query string, and URI and client gems put the url in the error for an invalid one.
    def self.without_url_in_errors(option: ":url", hint: nil, errors: [URI::InvalidURIError])
      yield
    rescue *errors => e
      raise(e.class, ["Invalid #{option}, it is not a valid URI.", hint].compact.join(" "), cause: nil)
    end

    # Returns [String] the scheme, host, and any non-default port of the url, which is safe to log.
    #
    # Everything else is left out, since log services carry credentials in each part of a url: the
    # user and password, the query string (for example a Datadog api key), and the path (for example
    # the token at the end of a Sumo Logic HTTP source url). An invalid url is not shown at all.
    def self.redacted_url(url)
      uri  = URI.parse(url.to_s)
      port = uri.port == uri.default_port ? nil : uri.port
      uri.class.build(scheme: uri.scheme, host: uri.host, port: port).to_s
    rescue URI::Error
      "(invalid url)"
    end

    # Returns the value, deep frozen so that code in any Ractor can read the constant or setting
    # that holds it.
    #
    # copy: false freezes the value itself, so only use it for a value that Semantic Logger owns, such
    # as one of its constants. A value this Ruby cannot share, such as an UnboundMethod before Ruby 4.0,
    # is returned unshareable, and may be left partly frozen. On a Ruby without Ractors (JRuby) the
    # value is returned as it is.
    #
    # copy: true leaves the supplied value as it is, and returns a deep frozen copy of it, for a value
    # that belongs to someone else, such as a setting. Without Ractors, or for a value Ruby cannot
    # copy, the copy is a shallow frozen dup.
    def self.make_shareable(value, copy: false)
      return copy ? frozen_dup(value) : value unless defined?(::Ractor)

      begin
        ::Ractor.make_shareable(value, copy: copy)
      rescue ::Ractor::Error, TypeError
        copy ? frozen_dup(value) : value
      end
    end

    # Returns a frozen shallow copy of the value, the value when it is already frozen, or the value
    # itself when it cannot be copied, such as a Thread.
    def self.frozen_dup(value)
      value.frozen? ? value : value.dup.freeze
    rescue TypeError
      value
    end
    private_class_method :frozen_dup

    # Borrow from Rails, when not running Rails
    def self.camelize(term)
      string = term.to_s
      string = string.sub(/^[a-z\d]*/, &:capitalize)
      string.gsub!(%r{(?:_|(/))([a-z\d]*)}i) { "#{Regexp.last_match(1)}#{Regexp.last_match(2).capitalize}" }
      string.gsub!("/".freeze, "::".freeze)
      string
    end

    # Extract the backtrace stripping off the leading semantic logger entries.
    # Leaves all other system and gem path entries in place.
    # Returns a new Array, leaving the supplied stack unchanged since it can belong to the caller.
    def self.extract_backtrace(stack = caller) = stack.drop_while { |path| extract_path?(path) }

    # Paths whose entries are stripped from the top of a captured backtrace.
    EXTRACT_PATHS = make_shareable(%w[lib/semantic_logger lib/rails_semantic_logger].freeze)

    def self.extract_paths = EXTRACT_PATHS

    # Whether this path should be excluded from any cleansed backtrace
    def self.extract_path?(path) = extract_paths.any? { |exclude| path.include?(exclude) }

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
      # A copy, since the paths are RubyGems' and RbConfig's own Strings.
      @strip_paths ||= make_shareable(Gem.path | [Gem.default_dir, RbConfig::CONFIG["rubylibdir"]], copy: true)
    end

    # Whether this path should be excluded from any cleansed backtrace
    def self.strip_path?(path) = strip_paths.any? { |exclude| path.start_with?(exclude) }

    # Returns [String] the exception's message, without raising the error that its #message raises.
    #
    # An exception class can override #message or #to_s with code that raises, such as code that
    # reads a record that is nil, or an abstract #message that raises NotImplementedError. Logging the
    # exception must not replace it with that error, such as the one that a measure_* block re-raises.
    # When #message raises a StandardError or a ScriptError, or does not return a String or an object
    # that converts to one, the message the exception was raised with is returned instead (see
    # .raised_message). Other errors, such as Interrupt, still propagate.
    def self.exception_message(exception)
      String(exception.message)
    rescue StandardError, ScriptError
      raised_message(exception)
    end

    # Returns [String] the message the exception was raised with, without what its class's own
    # #message or #to_s adds: its class name when it was raised without one. Its class name too when
    # that message cannot be converted to a String, since converting it raised a StandardError or a
    # ScriptError (see .exception_message).
    def self.raised_message(exception)
      Exception.instance_method(:to_s).bind_call(exception)
    rescue StandardError, ScriptError
      exception.class.to_s
    end

    # Serializes the value to JSON, repairing the data only when necessary.
    #
    # Data that JSON cannot represent appears in well under 1% of log events, so it
    # is wasteful to walk and reallocate the entire structure (see .json_safe) on
    # every call. Instead this attempts `.to_json` directly and only falls back to a
    # repaired copy when serialization fails because of the data:
    # * Invalid UTF-8. Depending on the json gem version this raises
    #   Encoding::UndefinedConversionError (an EncodingError) or JSON::GeneratorError.
    #   From json 3.1 so does a binary String that holds bytes outside ASCII, even valid UTF-8,
    #   which earlier versions write as UTF-8, with a warning that is dropped for log data (see
    #   CoreExt::Warning).
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
    #
    # That includes a value holding a binary String that json 2.8 through 3.0.x warn about, since
    # the writer's own serializing is not Semantic Logger's, so it would print the warning.
    def self.json_ready(value)
      CoreExt::Warning.unless_binary_string_warned { clean_json(value) } ? value : json_safe(value)
    end

    # The methods of this file that serialize log data to JSON (see .serializing_log_data?), as
    # their frames are named in a backtrace. A call one of them makes to a method written in C,
    # such as Hash#to_json, is named after that method but located in this file: "to_json".
    SERIALIZERS = make_shareable(%w[to_json clean_json json_safe_object json_safe_members].freeze)

    # Returns [true|false] whether the code running now was called by this file to serialize log
    # data, such as the json gem raising a warning (see CoreExt::Warning), or an object's own
    # #to_json in a payload: whether the innermost of this file's frames on the stack is one of
    # SERIALIZERS. When it is another of its methods, such as .exception_message calling
    # an exception's #message, the code is not serializing log data, even if log data is being
    # serialized further out.
    #
    # The stack is walked only as far as that frame, however deep it is, such as below nested
    # objects whose #to_json serializes a Hash, so that the answer does not depend on the depth.
    def self.serializing_log_data?
      Thread.each_caller_location { |frame| return SERIALIZERS.include?(frame.base_label) if frame.path == __FILE__ }
      false
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

    # Nesting depth after which .json_safe, and any other copy made by .bounded_structure,
    # replaces a Hash, Array, Struct, or Data with a placeholder. Well below the json gem's
    # default max_nesting of 100, leaving room for the levels that a formatter wraps the payload
    # in.
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
    # * Every String is converted to valid UTF-8, as by .encode_utf8, and so is the name of every
    #   Symbol, such as a Hash key, that is not UTF-8 or ASCII (see .encode_utf8_symbol).
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
      when Symbol then encode_utf8_symbol(value)
      when Float
        value.finite? ? value : value.to_s
      when Integer, NilClass, TrueClass, FalseClass
        value
      else
        return json_safe_object(value) unless structure?(value)

        bounded_structure(value, depth, ancestors) { |level, seen| json_safe_members(value, level, seen) }
      end
    end

    # Returns a bounded copy of a structure, such as a Hash or Array, for .json_safe, .encode_utf8,
    # or an appender that copies log data for a gem that writes it itself: what the block returns for its
    # members, given the next depth and the structures it is inside of, or, for one nested deeper
    # than MAX_JSON_SAFE_DEPTH or that holds itself, a placeholder String naming its class, such
    # as "#<Hash nested too deeply>", in place of the structure.
    def self.bounded_structure(value, depth, ancestors)
      ancestors ||= []
      if depth >= MAX_JSON_SAFE_DEPTH || ancestors.any? { |ancestor| ancestor.equal?(value) }
        return "#<#{value.class} nested too deeply>"
      end

      ancestors.push(value)
      begin
        yield depth + 1, ancestors
      ensure
        ancestors.pop
      end
    end

    # Returns any other object as it is, when JSON can write it, otherwise its #to_s converted
    # to valid UTF-8.
    def self.json_safe_object(value)
      value.to_json
      value
    rescue JSON::GeneratorError, EncodingError
      encode_utf8_string(value.to_s)
    end
    private_class_method :json_safe_object

    # Returns a copy of the members of a Hash, Array, Set, Struct, Data, or OpenStruct (see
    # .structure_members), each made safe by .json_safe at the supplied depth.
    def self.json_safe_members(value, depth, ancestors)
      members = structure_members(value)
      if members.is_a?(Hash)
        members.each_with_object({}) do |(key, val), hash|
          key       = json_safe(key, depth, ancestors)
          key       = key.to_json if key.is_a?(Hash) || key.is_a?(Array)
          hash[key] = json_safe(val, depth, ancestors)
        end
      elsif json_array?(value)
        members.map { |element| json_safe(element, depth, ancestors) }
      else
        # A #to_h that does not return a Hash is made safe one level deeper, so that the
        # recursion still ends.
        json_safe(members, depth, ancestors)
      end
    end
    private_class_method :json_safe_members

    # Returns [true|false] whether the value is a structure that the JSON formatters write as an array
    # of its own elements (see .structure_members): an Array or a Set.
    def self.json_array?(value) = value.is_a?(Array) || value.is_a?(::Set)

    # Returns the members of a structure (see .structure?), as the JSON formatters write them: a
    # Hash or an Array as it is, the elements of a Set as an Array, and the #to_h of a Struct, Data,
    # or OpenStruct, which is a Hash unless that method returns something else.
    def self.structure_members(value)
      case value
      when Hash, Array
        value
      when ::Set
        value.to_a
      else
        value.to_h
      end
    end

    # Returns a copy of the supplied value with every String converted to valid UTF-8, and every
    # Symbol whose name is not UTF-8 or ASCII converted the same way (see .encode_utf8_symbol).
    #
    # Recurses through Hash and Array structures, cleansing both keys and values.
    # Strings that are already valid UTF-8 are returned unchanged (the common case),
    # and so are Symbols that are UTF-8 or ASCII, so the fast path allocates nothing. Any
    # other value (Numeric, Time, nil, a Struct, ...) is returned as-is, without looking
    # inside it.
    #
    # A Hash or Array nested deeper than MAX_JSON_SAFE_DEPTH, or that holds itself, is
    # replaced where it is too deep or repeats with the placeholder that .json_safe writes,
    # such as "#<Hash nested too deeply>", so that the copy is bounded, as .json_safe is.
    #
    # Used by formatters that serialize per value or emit to a non-JSON sink (where a
    # single `.to_json` rescue boundary cannot catch an intermediate failure), and by
    # appenders that hand log data to a gem that writes it itself.
    def self.encode_utf8(value, depth = 0, ancestors = nil)
      case value
      when String
        encode_utf8_string(value)
      when Symbol then encode_utf8_symbol(value)
      when Hash, Array
        bounded_structure(value, depth, ancestors) { |level, seen| encode_utf8_members(value, level, seen) }
      else
        value
      end
    end

    # Returns a copy of the members of a Hash or Array, each converted by .encode_utf8.
    def self.encode_utf8_members(value, depth, ancestors)
      return value.map { |element| encode_utf8(element, depth, ancestors) } if value.is_a?(Array)

      value.each_with_object({}) do |(key, val), hash|
        hash[encode_utf8(key, depth, ancestors)] = encode_utf8(val, depth, ancestors)
      end
    end
    private_class_method :encode_utf8_members

    # Options used when transcoding a string to UTF-8.
    # Invalid byte sequences and characters that cannot be represented in UTF-8 are
    # dropped rather than substituted, matching the preference in issue #180.
    ENCODE_UTF8_OPTIONS = {invalid: :replace, undef: :replace, replace: "".freeze}.freeze

    # Returns the string converted to valid UTF-8, dropping any invalid bytes.
    #
    # Binary text, such as a response body, Base64-decoded text, or a C extension's error message,
    # and US-ASCII text that holds bytes outside ASCII, such as a file read where no locale is set,
    # do not say which characters those bytes are. They are read as the UTF-8 they usually hold,
    # keeping its characters, as the json gem did before 3.1. Converting them would drop every byte
    # outside ASCII, valid UTF-8 or not, since neither encoding defines one. Text in any other
    # encoding, such as ISO-8859-1, is converted.
    def self.encode_utf8_string(string)
      case string.encoding
      when Encoding::UTF_8
        string.valid_encoding? ? string : string.scrub("")
      when Encoding::BINARY, Encoding::US_ASCII
        read_as_utf8(string)
      else
        string.encode(Encoding::UTF_8, **ENCODE_UTF8_OPTIONS)
      end
    rescue EncodingError
      # Last resort for encodings without a converter to UTF-8. Logging must never raise.
      read_as_utf8(string)
    end

    # Returns [Symbol] the Symbol, or, when its name is neither UTF-8 nor ASCII, a Symbol named with
    # that name converted to valid UTF-8 (see .encode_utf8_string).
    #
    # A Symbol is named in the encoding of the text it was made from, such as a binary key from a
    # request turned into a Symbol, which JSON cannot always write once it holds bytes outside
    # ASCII: from json 3.1 not even valid UTF-8, and on CRuby with earlier versions not invalid
    # bytes, nor, from json 2.9, UTF-8 bytes tagged US-ASCII. A UTF-8 Symbol is always valid.
    def self.encode_utf8_symbol(symbol)
      symbol.name.ascii_only? || symbol.encoding == Encoding::UTF_8 ? symbol : encode_utf8_string(symbol.name).to_sym
    end

    # Returns [String] a copy of the string's bytes read as UTF-8, without its invalid bytes.
    private_class_method def self.read_as_utf8(string) = String.new(string, encoding: Encoding::UTF_8).scrub!("")

    # Returns [String] the texts joined into a new String, such as a log message and an exception's
    # message, whatever their encodings.
    #
    # Texts are joined as they are, so that text in an encoding such as ISO-8859-1 can still be
    # joined with the application's other text in that encoding. Two texts are converted to valid
    # UTF-8 first (see .encode_utf8_string) only when joining them would raise, such as for UTF-8
    # and binary texts that both hold bytes outside ASCII, or would make text that is not binary
    # binary, such as an ASCII message joined with a binary exception message.
    #
    # Each text is formatted as interpolation would, rather than added or converted with #to_s, so
    # that a String subclass whose #+ escapes the text added to it, such as
    # ActiveSupport::SafeBuffer, is joined as plain text, and an object whose #to_s does not return a
    # String is still joined.
    #
    # Plain Strings that are all UTF-8, the usual texts, always join as they are, so they are joined
    # without those checks, which take several times as long. With an explicit separator, so that a
    # global `$,` set by another library is not added between them.
    def self.join_texts(*texts)
      if texts.all? { |text| text.instance_of?(String) && text.encoding == Encoding::UTF_8 }
        return texts.join("") # rubocop:disable Style/RedundantArgument
      end

      texts.map { |text| format("%s", text) }.reduce do |joined, text|
        encoding = Encoding.compatible?(joined, text)
        if encoding && (encoding != Encoding::BINARY || joined.encoding == Encoding::BINARY)
          "#{joined}#{text}"
        else
          "#{encode_utf8_string(joined)}#{encode_utf8_string(text)}"
        end
      end
    end
  end
end
