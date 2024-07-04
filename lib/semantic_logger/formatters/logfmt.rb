require "json"

module SemanticLogger
  module Formatters
    # Produces logfmt formatted messages
    #
    # The following fields are extracted from the raw log and included in the formatted message:
    #   :timestamp, :level, :name, :message, :duration, :tags, :named_tags
    #
    # E.g.
    #   timestamp="2020-07-20T08:32:05.375276Z" level=info name="DefaultTest" base="breakfast" spaces="second breakfast" double_quotes="\"elevensies\"" single_quotes="'lunch'" tag="success"
    #
    # All timestamps are ISO8601 formatteed
    # All user supplied values are escaped and surrounded by double quotes to avoid ambiguious message delimeters
    # `tags` are treated as keys with boolean values. Tag names are not formatted or validated, ensure you use valid logfmt format for tag names.
    # `named_tags` are flattened are merged into the top level message field. Any conflicting fields are overridden.
    # `payload` values take precedence over `tags` and `named_tags`. Any conflicting fields are overridden.
    #
    # Futher Reading https://brandur.org/logfmt
    class Logfmt < Raw
      def initialize(time_format: :iso_8601, time_key: :timestamp, **args)
        super(time_format: time_format, time_key: time_key, **args)
      end

      def call(log, logger)
        @raw = super(log, logger)

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
        tags = @raw.fetch(:tags){ [] }
                    .each_with_object({}){ |tag, accum| accum[tag] = true }

        @parsed = @parsed.merge(tags)
                         .merge(@raw.fetch(:named_tags){ {} })
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
        flattened = @parsed.map do |key, value|
          case value
          when Hash, Array
            "#{key}=#{value.to_s.to_json}"
          else
            "#{key}=#{value.to_json}"
          end
        end

        flattened.join(" ")
      end
    end
  end
end
