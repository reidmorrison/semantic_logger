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

      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
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

        @parsed.merge!(@raw[:payload])
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
      def flatten_log
        seen = {}
        line = +""
        @parsed.each_pair do |key, value|
          key = logfmt_key(key)
          next if seen.key?(key)

          seen[key] = true
          line << " " unless line.empty?
          line << key << "=" << format_value(value)
        end
        line
      end

      def format_value(value)
        case value
        when Hash, Array
          Utils.to_json(value.to_s)
        else
          Utils.to_json(value)
        end
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
