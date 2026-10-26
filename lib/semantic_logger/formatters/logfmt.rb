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
    # replaced with `_`, so that untrusted data cannot inject fields or lines.
    # `tags`, `named_tags`, and `payload` are flattened into the top level fields. A key named like
    # one of the entry's own fields (the time key, `level`, `name`, `message`, `duration`,
    # `duration_ms`, `tag`) or an exception field is prefixed with its source, as in `payload.level`,
    # so that logged data cannot replace those fields. Other keys that are the same once encoded,
    # such as `:user` and `"user"`, or `"a b"` and `"a=b"`, are written once, with the value from the
    # later source: `payload` values take precedence over `named_tags`, and `named_tags` over `tags`.
    # An exception is emitted as `exception_name`, `exception_message`, `stack_trace`, and `cause`,
    # and with `log_exception_details` also `exception_details`.
    #
    # Futher Reading https://brandur.org/logfmt
    class Logfmt < Raw
      # The entry's own fields in the Raw hash, written in this order after the time key.
      ENTRY_FIELDS = %i[level name message duration duration_ms].freeze

      # The field that tells an entry with an exception from one without.
      TAG_FIELD = "tag".freeze

      # The exception's fields in the Raw hash, mapped to their logfmt names, so that the exception's
      # name and message do not replace the entry's own.
      EXCEPTION_FIELDS = {
        name:        "exception_name",
        message:     "exception_message",
        details:     "exception_details",
        stack_trace: "stack_trace",
        cause:       "cause"
      }.freeze

      # Prefixes that mark a key from logged data with its source, when the key alone would name
      # one of the entry's own fields.
      TAGS_PREFIX       = "tags.".freeze
      NAMED_TAGS_PREFIX = "named_tags.".freeze
      PAYLOAD_PREFIX    = "payload.".freeze

      # Characters that cannot appear in a logfmt key: spaces and other control characters, which
      # would end the key or the line, the `=` and `"` delimiters, and the Unicode line breaks
      # NEL, LINE SEPARATOR, and PARAGRAPH SEPARATOR, which some readers treat as newlines.
      UNSAFE_KEY_CHARS = /[\x00-\x20="\x7f\u0085\u2028\u2029]/

      # The ASCII subset of UNSAFE_KEY_CHARS, which is much faster to match against the ASCII keys
      # that make up nearly every log event.
      UNSAFE_ASCII_KEY_CHARS = /[\x00-\x20="\x7f]/

      # The most Symbol keys to remember the names of, so that untrusted keys cannot grow the cache
      # without bound.
      PLAIN_SYMBOL_CACHE_SIZE = 512

      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        super
        name_entry_fields
      end

      # Also writes and reserves the new time key in place of the old one.
      def time_key=(time_key)
        super
        name_entry_fields
      end

      def call(log, logger)
        @raw = super

        raw_to_logfmt
      end

      private

      # @parsed maps the logfmt name of each field to its value. Logged data is added after the
      # entry's own fields, and a field with the same name as an earlier one replaces its value, so
      # the payload takes precedence over named tags, and named tags over tags.
      def raw_to_logfmt
        @parsed            = @raw.slice(*@entry_keys).transform_keys(@entry_names)
        @parsed[TAG_FIELD] = "success"
        handle_tags
        handle_payload
        handle_exception

        flatten_log
      end

      def handle_tags
        @raw[:tags]&.each { |tag| add_field(TAGS_PREFIX, tag, true) }
        @raw[:named_tags]&.each_pair { |key, value| add_field(NAMED_TAGS_PREFIX, key, value) }
      end

      def handle_payload
        return unless @raw.key? :payload

        payload = @raw[:payload]
        # A payload is normally a Hash, but a log call can supply any value, so emit anything else
        # as a single field rather than failing to format the whole entry.
        if payload.is_a?(Hash)
          payload.each_pair { |key, value| add_field(PAYLOAD_PREFIX, key, value) }
        else
          add_field(PAYLOAD_PREFIX, "payload", payload)
        end
      end

      def handle_exception
        return unless @raw.key? :exception

        @parsed[TAG_FIELD] = "exception"
        @raw[:exception].each_pair { |key, value| @parsed[EXCEPTION_FIELDS[key] || logfmt_key(key)] = value }
      end

      # Adds a field from logged data, under the name returned by #field_name.
      def add_field(prefix, key, value)
        name          = (key.is_a?(Symbol) && @plain_symbols[key]) || field_name(prefix, key)
        @parsed[name] = value
      end

      # Returns [String] the logfmt name of a key from logged data: the key encoded by #logfmt_key,
      # prefixed with its source, as in "payload.level", when it names one of the entry's own fields,
      # so that untrusted data cannot replace or forge that field.
      def field_name(prefix, key)
        name = key.is_a?(Symbol) ? key.name : key.to_s
        name = logfmt_key(name) unless plain_name?(name)
        return prefix + name if @reserved_names.key?(name)

        remember_symbol(key, name) if key.is_a?(Symbol)
        name
      end

      # Remembers the name of a Symbol key that is not reserved, while there is room. The cache is
      # replaced rather than updated, since a formatter can be shared by several threads.
      def remember_symbol(symbol, name)
        plain_symbols  = @plain_symbols
        @plain_symbols = plain_symbols.merge(symbol => name).freeze if plain_symbols.size < PLAIN_SYMBOL_CACHE_SIZE
      end

      def flatten_log
        line = +""
        @parsed.each_pair do |name, value|
          line << " " unless line.empty?
          line << name << "=" << format_value(value)
        end
        line
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

      # Names the entry's own fields from the time key, and reserves those names and the
      # exception's, so that logged data cannot use them.
      def name_entry_fields
        @entry_names    = [time_key, *ENTRY_FIELDS].to_h { |key| [key, logfmt_key(key)] }.freeze
        @entry_keys     = @entry_names.keys.freeze
        @reserved_names = [*@entry_names.values, TAG_FIELD, *EXCEPTION_FIELDS.values].
                          to_h { |name| [name, true] }.freeze
        # Symbol keys from logged data that need no prefix, mapped to their logfmt names.
        @plain_symbols = {}.freeze
      end

      # Whether the name is already a valid logfmt key, made of ASCII characters that are all safe.
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
