begin
  require "honeybadger"
rescue LoadError
  raise LoadError, 'Gem honeybadger is required for logging purposes. Please add the gem "honeybadger" to your Gemfile.'
end

# Send log messages to honeybadger events/insights API
#
# Example:
#   SemanticLogger.add_appender(appender: :honeybadger_insights)
#
module SemanticLogger
  module Appender
    class HoneybadgerInsights < SemanticLogger::Subscriber
      # Honeybadger Appender
      #
      # Parameters
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: :error
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      def initialize(level: :info, **args, &block)
        super
      end

      # Send log to honeybadger events API
      #
      # Honeybadger replaces each byte of text that is not valid UTF-8 with "?", including binary text
      # that holds UTF-8, such as a response body, so the data is sent as a copy with its text
      # converted to valid UTF-8, as the JSON formatters write it, and a Hash or Array nested too
      # deeply, or that holds itself, cut off there as they cut it off (see Utils.encode_utf8). Any
      # other object is sent as it is, for Honeybadger to clean.
      def log(log)
        event = format_log(log) { |data| Utils.encode_utf8(data) }.merge(event_type: "log")

        ::Honeybadger.event(event)

        true
      end

      private

      # Use Raw Formatter by default
      def default_formatter
        SemanticLogger::Formatters::Raw.new(time_key: :ts, time_format: :rfc_3339)
      end
    end
  end
end
