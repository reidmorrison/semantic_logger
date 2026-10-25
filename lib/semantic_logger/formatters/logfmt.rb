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
    # `named_tags` are flattened are merged into the top level message field. Any conflicting fields are overridden.
    # `payload` values take precedence over `tags` and `named_tags`. Any conflicting fields are overridden.
    #
    # Futher Reading https://brandur.org/logfmt
    class Logfmt < Raw
      # Characters that cannot appear in a logfmt key: spaces and other control characters, which
      # would end the key or the line, and the `=` and `"` delimiters.
      UNSAFE_KEY_CHARS = /[\x00-\x20="\x7f]/

      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        super
      end

      def call(log, logger)
        @raw = super

        raw_to_logfmt
      end

      private

      def raw_to_logfmt
        @parsed = @raw.slice(time_key, :level, :name, :message, :duration, :duration_ms).merge(tag: "success")
        handle_tags
        handle_payload
        handle_exception

        flatten_log
      end

      def handle_tags
        tags = @raw.fetch(:tags) { [] }.
               each_with_object({}) { |tag, accum| accum[tag] = true }

        @parsed = @parsed.merge(tags).
                  merge(@raw.fetch(:named_tags) { {} })
      end

      def handle_payload
        return unless @raw.key? :payload

        @parsed = @parsed.merge(@raw[:payload])
      end

      def handle_exception
        return unless @raw.key? :exception

        @parsed[:tag] = "exception"
        @parsed = @parsed.merge(@raw[:exception])
      end

      def flatten_log
        # Keyed by the encoded key, so that keys which only differ by type, such as :level and
        # "level", produce a single field. Later values take precedence, as with the merges above.
        fields = {}
        @parsed.each_pair { |key, value| fields[logfmt_key(key)] = value }

        flattened = fields.map do |key, value|
          case value
          when Hash, Array
            "#{key}=#{Utils.to_json(value.to_s)}"
          else
            "#{key}=#{Utils.to_json(value)}"
          end
        end

        flattened.join(" ")
      end

      # Returns [String] the key with every character that would break the logfmt structure
      # replaced by an underscore. Keys come from tags, named tags, and payloads, which can hold
      # untrusted data; unescaped, they could inject fields or forge an entire line.
      def logfmt_key(key)
        key = key.to_s.gsub(UNSAFE_KEY_CHARS, "_")
        key.empty? ? "_" : key
      end
    end
  end
end
