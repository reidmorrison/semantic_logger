begin
  require "sentry-raven"
rescue LoadError
  raise LoadError, 'Gem sentry-raven is required for logging purposes. Please add the gem "sentry-raven" to your Gemfile.'
end

# Send log messages to sentry
#
# Example:
#   SemanticLogger.add_appender(appender: :sentry)
#
module SemanticLogger
  module Appender
    class Sentry < SemanticLogger::Subscriber
      # Create Appender
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
        # Replace the Sentry Raven logger so that we can identify its log messages and not forward them to Sentry
        Raven.configure { |config| config.logger = SemanticLogger[Raven] }
        super(level: level, **args, &block)
      end

      # Send an error notification to sentry
      def log(log)
        # Ignore logs coming from Raven itself
        return false if log.name == "Raven"

        context      = formatter.call(log, self)
        user         = context.delete(:user)
        tags         = context.delete(:tags)
        attrs        = {
          level: context.delete(:level),
          extra: context
        }
        attrs[:user] = user if user
        attrs[:tags] = tags if tags
        if log.exception
          context.delete(:exception)
          Raven.capture_exception(log.exception, attrs)
        else
          attrs[:extra][:backtrace] = log.backtrace if log.backtrace
          Raven.capture_message(context[:message], attrs)
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
