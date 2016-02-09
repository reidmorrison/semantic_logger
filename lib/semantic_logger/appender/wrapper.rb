# Send log messages to any standard Ruby logging class.
#
#  Forwards logging call to loggers such as Logger, log4r, etc.
#
module SemanticLogger
  module Appender
    class Wrapper < SemanticLogger::Appender::Base
      attr_reader :logger

      # Forward all logging calls to the supplied logging instance.
      #
      # Parameters
      #   logger: [Object]
      #     Instance of an existing logger conforming to the Ruby Logger methods.
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      # Ruby Logger
      #    require 'logger'
      #    require 'semantic_logger'
      #
      #    ruby_logger = Logger.new(STDOUT)
      #    SemanticLogger.add_appender(ruby_logger)
      #
      #    logger =  SemanticLogger['test']
      #    logger.info('Hello World', some: :payload)
      #
      # Enhance the Rails Logger
      #    # Add the Rails logger to the list of appenders
      #    SemanticLogger.add_appender(Rails.logger)
      #    Rails.logger = SemanticLogger['Rails']
      #
      #    # Make ActiveRecord logging include its class name in every log entry
      #    ActiveRecord::Base.logger = SemanticLogger['ActiveRecord']
      #
      # Install the `rails_semantic_logger` gem to replace the Rails logger with Semantic Logger.
      def initialize(logger, level = nil, filter = nil, &block)
        raise 'logger cannot be null when initializing the SemanticLogging::Appender::Wrapper' unless logger
        @logger    = logger

        # Set the formatter to the supplied block
        @formatter = block || self.default_formatter
        super(level, filter, &block)
      end

      # Pass log calls to the underlying Rails, log4j or Ruby logger
      #  trace entries are mapped to debug since :trace is not supported by the
      #  Ruby or Rails Loggers
      def log(log)
        # Ensure minimum log level is met, and check filter
        return false if (level_index > (log.level_index || 0)) || !include_message?(log)

        # Underlying wrapper logger implements log level, so don't check here
        @logger.send(log.level == :trace ? :debug : log.level, @formatter.call(log, self))
        true
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be writted to disk
      def flush
        @logger.flush if @logger.respond_to?(:flush)
      end

    end
  end
end
