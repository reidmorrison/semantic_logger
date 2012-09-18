# Wrapper appender
#
#   Wraps the Rails log, log4r, or Ruby Logger with the SemanticLogger API's
#
module SemanticLogger
  module Appender
    class Wrapper < SemanticLogger::Base
      attr_reader :logger

      # Create a Logger or Rails Logger appender instance
      #
      # Ruby Logger
      #    require 'logger'
      #    require 'semantic_logger'
      #    ruby_logger = Logger.new(STDOUT)
      #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::Wrapper.new(ruby_logger)
      #    logger =  SemanticLogger::Logger.new('test')
      #    logger.info('Hello World', :some => :payload)
      #
      # Enhance the Rails Logger
      #    # Add the Rails logger to the list of appenders
      #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::Wrapper.new(Rails.logger)
      #    Rails.logger = SemanticLogger::Logger.new('Rails')
      #
      #    # Make ActiveRecord logging include its class name in every log entry
      #    ActiveRecord::Base.logger = SemanticLogger::Logger.new('ActiveRecord')
      #
      # Note: Since the log level is controlled by setting the Ruby or Rails logger directly
      #   the level is ignored for this appender
      def initialize(logger, &block)
        raise "logger cannot be null when initiailizing the SemanticLogging::Appender::Logger" unless logger
        @logger = logger

        # Set the formatter to the supplied block
        @formatter = block || self.default_formatter
        super(:trace, &block)
      end

      # TODO Compatible calls to #level and #level= against the underlying Rails/Ruby logger

      # Pass log calls to the underlying Rails, log4j or Ruby logger
      #  trace entries are mapped to debug since :trace is not supported by the
      #  Ruby or Rails Loggers
      def log(log)
        @logger.send(log.level == :trace ? :debug : log.level, @formatter.call(log))
      end

      # Flush all pending logs to disk.
      #  Waits for all sent documents to be writted to disk
      def flush
        @logger.flush if @logger.respond_to?(:flush)
      end

    end
  end
end
