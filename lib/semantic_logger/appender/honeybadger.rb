begin
  require "honeybadger"
rescue LoadError
  raise LoadError, 'Gem honeybadger is required for logging purposes. Please add the gem "honeybadger" to your Gemfile.'
end

# Send log messages to honeybadger
#
# Example:
#   SemanticLogger.add_appender(appender: :honeybadger)
#
module SemanticLogger
  module Appender
    class Honeybadger < SemanticLogger::Subscriber
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
      def initialize(level: :error, **args, &block)
        super
      end

      # Captures the backtrace of the code that logged an entry without an exception, which Honeybadger
      # shows as the backtrace of its notice (see Log#capture_backtrace!). An exception carries its own.
      CAPTURE_BACKTRACE = ->(log) { log.capture_backtrace! unless log.exception }

      # Returns [Array<#call>] the captures of its formatter, and that of the backtrace of the thread
      # that logs each entry that it sends (see CAPTURE_BACKTRACE).
      def source_captures
        [*super, CAPTURE_BACKTRACE]
      end

      # Send an error notification to honeybadger
      #
      # Honeybadger replaces each byte of text that is not valid UTF-8 with "?", including binary text
      # that holds UTF-8, such as a response body, so the data is sent as a copy with its text
      # converted to valid UTF-8, as the JSON formatters write it, and a Hash or Array nested too
      # deeply, or that holds itself, cut off there as they cut it off (see Utils.encode_utf8). Any
      # other object is sent as it is, for Honeybadger to clean.
      def log(log)
        context = format_log(log) { |data| Utils.encode_utf8(data) }
        if log.exception
          context.delete(:exception)
          ::Honeybadger.notify(log.exception, context)
        else
          message = {
            error_class:   context.delete(:name),
            error_message: context.delete(:message),
            context:       context
          }
          message[:backtrace] = log.backtrace if log.backtrace
          ::Honeybadger.notify(message)
        end
        true
      end

      private

      # Use Raw Formatter by default
      def default_formatter
        SemanticLogger::Formatters::Raw.new
      end
    end
  end
end
