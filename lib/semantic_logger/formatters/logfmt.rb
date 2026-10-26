require "json"

module SemanticLogger
  module Formatters
    # Produces logfmt formatted messages
    #
    # The following fields are extracted from the raw log and included in the formatted message:
    #   :timestamp, :level, :name, :message, :duration, :tags, :named_tags
    #
    # E.g.
    #   timestamp="2020-07-20T08:32:05.375276Z" level=info name="DefaultTest" base="breakfast"
    #   spaces="second breakfast" double_quotes="\"elevensies\"" single_quotes="'lunch'" tag="success"
    #
    # All timestamps are ISO8601 formatteed
    # All user supplied values are escaped and surrounded by double quotes to avoid ambiguious message delimeters
    # `tags` are treated as keys with boolean values.
    # In every key (tags, named tags, payload), spaces, control characters, `=`, and `"` are
    # replaced with `_`, so that untrusted data cannot inject fields or lines. Keys that only match
    # once encoded, or only differ by type (`:level` and `"level"`), keep the earlier field.
    # `named_tags` are flattened are merged into the top level message field. Any conflicting fields are overridden.
    # `payload` values take precedence over `tags` and `named_tags`. Any conflicting fields are overridden.
    #
    # Futher Reading https://brandur.org/logfmt
    class Logfmt < Raw
      # Characters that cannot appear in a logfmt key: spaces and other control characters, which
      # would end the key or the line, the `=` and `"` delimiters, and the Unicode line breaks
      # NEL, LINE SEPARATOR, and PARAGRAPH SEPARATOR, which some readers treat as newlines.
      UNSAFE_KEY_CHARS = /[\x00-\x20="\x7f\u0085\u2028\u2029]/

      # The ASCII subset of UNSAFE_KEY_CHARS, which is much faster to match against the ASCII keys
      # that make up nearly every log event.
      UNSAFE_ASCII_KEY_CHARS = /[\x00-\x20="\x7f]/

      # The most Symbol keys to remember as plain, so that untrusted keys cannot grow the cache
      # without bound.
      PLAIN_SYMBOL_CACHE_SIZE = 512

      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        # Symbol keys known to be plain, mapped to their names. It is replaced rather than
        # updated, since a formatter can be shared by several threads.
        @plain_symbols = {}.freeze
        super
      end

      def call(log, logger)
        @raw = super

        raw_to_logfmt
      end

      private

      def raw_to_logfmt
        # The merges below update @parsed in place, since it is a new Hash owned by this call.
        @parsed       = @raw.slice(time_key, :level, :name, :message, :duration, :duration_ms)
        @parsed[:tag] = "success"
        handle_tags
        handle_payload
        handle_exception

        flatten_log
      end

      def handle_tags
        @raw[:tags]&.each { |tag| @parsed[tag] = true }
        @parsed.merge!(@raw[:named_tags]) if @raw.key?(:named_tags)
      end

      def handle_payload
        return unless @raw.key? :payload

        payload = @raw[:payload]
        # A payload is normally a Hash, but a log call can supply any value, so emit anything else
        # as a single field rather than failing to format the whole entry.
        if payload.is_a?(Hash)
          @parsed.merge!(payload)
        else
          @parsed[:payload] = payload
        end
      end

      def handle_exception
        return unless @raw.key? :exception

        @parsed[:tag] = "exception"
        @parsed.merge!(@raw[:exception])
      end

      # Keys that collide only once encoded, such as :level and "level", or "duration ms" and
      # :duration_ms, are emitted once: the first field wins, so a tag, named tag, or payload
      # key cannot replace a core field this way. Identical keys were already resolved by the
      # merges above, where the payload deliberately takes precedence.
      #
      # Nearly every entry only has plain keys that cannot collide, so the emitted keys are only
      # tracked from the first key that could collide with another.
      def flatten_log
        line = +""
        seen = nil
        @parsed.each_pair do |key, value|
          name = plain_key(key)
          if seen || name.nil?
            seen ||= keys_before(key)
            name ||= logfmt_key(key)
            next if seen.key?(name)

            seen[name] = true
          end
          line << " " unless line.empty?
          line << name << "=" << format_value(value)
        end
        line
      end

      # Returns [Hash] the encoded keys of the fields before the given key, all of them plain.
      def keys_before(key)
        seen = {}
        @parsed.each_key do |earlier|
          break if earlier.equal?(key)

          seen[plain_key(earlier)] = true
        end
        seen
      end

      # Integers, true, false, and nil have a single JSON form, so they skip the cost of `to_json`.
      # Strings, the most common values, are checked first.
      def format_value(value)
        return Utils.to_json(value) if value.is_a?(String)

        case value
        when Integer, true, false
          value.to_s
        when nil
          "null"
        else
          # The JSON form rather than #inspect, which can print an object's instance variables
          # and has no depth limit. A structure is quoted, since its JSON holds spaces and quotes.
          json = Utils.to_json(value)
          json.start_with?("{", "[") ? Utils.to_json(json) : json
        end
      end

      # Returns [String] the key itself when it is already a valid logfmt key that no other key
      # in this entry can collide with, otherwise nil.
      #
      # Such a key is a plain String or Symbol made of ASCII characters that are all safe in a
      # logfmt key. Two of them can only encode to the same text when one is a Symbol and the
      # other a String with the same name, since equal Strings, or equal Symbols, are the same
      # Hash key.
      def plain_key(key)
        if key.is_a?(Symbol)
          name = @plain_symbols[key] || plain_symbol(key)
          name unless name.nil? || @parsed.key?(name)
        elsif key.instance_of?(String)
          key if plain_name?(key)
        end
      end

      # Returns [String] the name of the Symbol when it is plain, and remembers it while there
      # is room.
      def plain_symbol(symbol)
        name = symbol.name
        return unless plain_name?(name)

        plain_symbols  = @plain_symbols
        @plain_symbols = plain_symbols.merge(symbol => name).freeze if plain_symbols.size < PLAIN_SYMBOL_CACHE_SIZE
        name
      end

      def plain_name?(name)
        !name.empty? && name.ascii_only? && !name.match?(UNSAFE_ASCII_KEY_CHARS)
      end

      # Returns [String] the key as valid UTF-8, with every character that would break the logfmt
      # structure replaced by an underscore. Keys come from tags, named tags, and payloads, which
      # can hold untrusted data; unescaped, they could inject fields or forge an entire line.
      def logfmt_key(key)
        key = key.is_a?(Symbol) ? key.name : key.to_s
        unsafe = UNSAFE_ASCII_KEY_CHARS
        unless key.ascii_only?
          key    = Utils.encode_utf8_string(key)
          unsafe = UNSAFE_KEY_CHARS
        end
        key = key.gsub(unsafe, "_") if key.match?(unsafe)
        key.empty? ? "_" : key
      end
    end
  end
end
