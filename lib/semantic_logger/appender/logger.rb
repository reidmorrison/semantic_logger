# Logger appender
#
#   Maps the SemanticLogger API's to the Rails log, log4j, or Ruby Logger
#
# The log level is controlled by the Logging implementation passed into
# this appender
module SemanticLogger
  module Appender
    class Logger
      attr_reader :logger

      # Create a Logger or Rails Logger appender instance
      #
      # Ruby Logger
      #    require 'logger'
      #    require 'semantic_logger'
      #    ruby_logger = Logger.new(STDOUT)
      #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::Logger.new(ruby_logger)
      #    logger =  SemanticLogger::Logger.new('test')
      #    logger.info('Hello World', :some => :payload)
      #
      # Enhance the Rails Logger
      #    # Add the Rails logger to the list of appenders
      #    SemanticLogger::Logger.appenders << SemanticLogger::Appender::Logger.new(Rails.logger)
      #    Rails.logger = SemanticLogger::Logger.new('Rails')
      #
      #    # Make ActiveRecord logging include its class name in every log entry
      #    ActiveRecord::Base.logger = SemanticLogger::Logger.new('ActiveRecord')
      def initialize(logger, &block)
        raise "logger cannot be null when initiailizing the SemanticLogging::Appender::Logger" unless logger
        @logger = logger

        # Set the formatter to the supplied block
        @formatter = block || self.default_formatter
      end

      # Default log formatter
      #  Replace this formatter by supplying a Block to the initializer
      #  Generates logs of the form:
      #    2011-07-19 14:36:15.660 D [1149:ScriptThreadProcess] Rails -- Hello World
      def default_formatter
        Proc.new do |log|
          message = log.message.to_s
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

          if log.payload
            if log.payload.is_a?(Exception)
              exception = log.payload
              message << " -- " << "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
            else
              message << " -- " << log.payload.inspect
            end
          end

          str = "#{log.time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%03d" % (log.time.usec/1000)} #{log.level.to_s[0..0].upcase} [#{$$}:#{log.thread_name}] #{tags}#{log.name} -- #{message}"
          str << " (#{'%.1f' % log.duration}ms)" if log.duration
          str
        end
      end

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
