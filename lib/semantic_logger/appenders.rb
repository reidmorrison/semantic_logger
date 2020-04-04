module SemanticLogger
  # Manage a collection of appenders.
  class Appenders < Concurrent::Array
    attr_accessor :logger

    def initialize(logger = Processor.logger.dup)
      @logger      = logger
      @logger.name = self.class.name
    end

    def add(**args, &block)
      appender = SemanticLogger::Appender.factory(**args, &block)
      self << appender
      appender
    end

    def log(log)
      each do |appender|
        begin
          appender.log(log) if appender.should_log?(log)
        rescue Exception => e
          logger.error "Failed to log to appender: #{appender.name}", e
        end
      end
    end

    def flush
      each do |appender|
        begin
          logger.trace "Flushing appender: #{appender.name}"
          appender.flush
        rescue Exception => e
          logger.error "Failed to flush appender: #{appender.name}", e
        end
      end
      logger.trace "All appenders flushed"
    end

    def close
      each do |appender|
        begin
          logger.trace "Closing appender: #{appender.name}"
          appender.flush
          appender.close
          delete(appender)
        rescue Exception => e
          logger.error "Failed to close appender: #{appender.name}", e
        end
      end
      logger.trace "All appenders closed and removed from appender list"
    end

    # After a fork the appender thread is not running, start it if it is not running.
    def reopen
      each do |appender|
        begin
          next unless appender.respond_to?(:reopen)

          logger.trace "Reopening appender: #{appender.name}"
          appender.reopen
        rescue Exception => e
          logger.error "Failed to re-open appender: #{appender.name}", e
        end
      end
      logger.trace "All appenders re-opened"
    end
  end
end
