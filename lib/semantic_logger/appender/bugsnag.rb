begin
  require "bugsnag"
rescue LoadError
  raise LoadError, 'Gem bugsnag is required for logging purposes. Please add the gem "bugsnag" to your Gemfile.'
end

# Send log messages to Bugsnag
#
# Example:
#   SemanticLogger.add_appender(appender: :bugsnag)
#
module SemanticLogger
  module Appender
    class Bugsnag < SemanticLogger::Subscriber
      # Create Bugsnag Error / Exception Appender
      #
      # Parameters
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: :error
      #
      #   formatter: [Object|Proc]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: Use the built-in formatter (See: #call)
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      def initialize(level: :error, **args, &block)
        raise "Bugsnag only supports :info, :warn, or :error log levels" unless %i[info warn error fatal].include?(level)

        # Replace the Bugsnag logger so that we can identify its log messages and not forward them to Bugsnag
        ::Bugsnag.configure { |config| config.logger = SemanticLogger[Bugsnag] }

        super(level: level, **args, &block)
      end

      # Returns [Hash] of parameters to send to Bugsnag.
      def call(log, logger)
        hash = SemanticLogger::Formatters::Raw.new.call(log, logger)
        hash.delete(:message) if hash[:exception] && (hash[:message] == hash[:exception][:message])
        hash.delete(:time)
        hash.delete(:level_index)
        hash.delete(:exception)
        hash[:file] = "#{hash[:file]}:#{hash.delete(:line)}" if hash.key?(:file)
        hash
      end

      def log(log)
        # Ignore logs coming from Bugsnag itself
        return false if log.name == "Bugsnag"

        # Send error messages as Runtime exceptions
        exception = extract_exception(log)
        hash      = formatter.call(log, self)
        bugsnag_notify(exception, hash, log_level(log.level))
        true
      end

      private

      def bugsnag_notify(exception, hash, level)
        if ::Bugsnag::VERSION.to_i >= 6
          ::Bugsnag.notify(exception) do |report|
            report.severity = level
            hash.each_pair { |key, value| report.add_tab(key, value) }
          end
        else
          hash[:severity] = level
          ::Bugsnag.notify(exception, hash)
        end
      end

      def extract_exception(log)
        if log.exception
          # Manually constructed Exception, without a backtrace.
          log.exception.set_backtrace(log.backtrace) if !log.exception.backtrace && log.backtrace
          return log.exception
        end

        error = RuntimeError.new(log.message)
        error.set_backtrace(log.backtrace) if log.backtrace
        error
      end

      # Bugsnag supports: error, warning or info
      def log_level(level)
        case level
        when :error, :fatal
          "error"
        when :warn
          "warning"
        else
          "info"
        end
      end
    end
  end
end
