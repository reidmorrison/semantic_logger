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

      if appender.respond_to?(:console_output?) && appender.console_output? && console_output?
        logger.warn "Ignoring attempt to add a second console appender: #{appender.class.name} since it would result in duplicate console output."
        return
      end

      self << appender
      appender
    end

    # Whether any of the existing appenders already output to the console?
    # I.e. Writes to stdout or stderr.
    def console_output?
      any? { |appender| appender.respond_to?(:console_output?) && appender.console_output? }
    end

    def log(log)
      each do |appender|
        appender.log(log) if appender.should_log?(log)
      rescue Exception => e
        logger.error "Failed to log to appender: #{appender.name}", e
      end
    end

    def flush
      each do |appender|
        logger.trace "Flushing appender: #{appender.name}"
        appender.flush
      rescue Exception => e
        logger.error "Failed to flush appender: #{appender.name}", e
      end
      logger.trace "All appenders flushed"
    end

    def close
      to_a.each do |appender|
        logger.trace "Closing appender: #{appender.name}"
        delete(appender)
        appender.flush
        appender.close
      rescue Exception => e
        logger.error "Failed to close appender: #{appender.name}", e
      end
      logger.trace "All appenders closed and removed from appender list"
    end

    # After a fork the appender thread is not running, start it if it is not running.
    def reopen
      each do |appender|
        next unless appender.respond_to?(:reopen)

        logger.trace "Reopening appender: #{appender.name}"
        appender.reopen
      rescue Exception => e
        logger.error "Failed to re-open appender: #{appender.name}", e
      end
      logger.trace "All appenders re-opened"
    end
  end
end
