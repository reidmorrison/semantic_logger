module SemanticLogger
  # Manage a collection of appenders.
  class Appenders < Concurrent::Array
    attr_accessor :logger

    def initialize(logger = Processor.logger.dup)
      @logger      = logger
      @logger.name = self.class.name
    end

    def add(options, deprecated_level = nil, &block)
      options  = options.is_a?(Hash) ? options.dup : convert_old_appender_args(options, deprecated_level)
      appender = SemanticLogger::Appender.factory(options, &block)
      self << appender
      appender
    end

    def log(log)
      each do |appender|
        begin
          appender.log(log) if appender.should_log?(log)
        rescue Exception => exc
          logger.error "Failed to log to appender: #{appender.inspect}", exc
        end
      end
    end

    def flush
      each do |appender|
        begin
          logger.trace "Flushing appender: #{appender.name}"
          appender.flush
        rescue Exception => exc
          logger.error "Failed to flush appender: #{appender.inspect}", exc
        end
      end
      logger.trace 'All appenders flushed'
    end

    def close
      each do |appender|
        begin
          logger.trace "Closing appender: #{appender.name}"
          appender.flush
          appender.close
          appenders.delete(appender)
        rescue Exception => exc
          logger.error "Failed to close appender: #{appender.inspect}", exc
        end
      end
      logger.trace 'All appenders closed and removed from appender list'
    end

    # After a fork the appender thread is not running, start it if it is not running.
    def reopen
      each do |appender|
        begin
          next unless appender.respond_to?(:reopen)

          logger.trace "Reopening appender: #{appender.name}"
          appender.reopen
        rescue Exception => exc
          logger.error "Failed to re-open appender: #{appender.inspect}", exc
        end
      end
      logger.trace 'All appenders re-opened'
    end

    private

    # Backward compatibility
    def convert_old_appender_args(appender, level)
      options         = {}
      options[:level] = level if level

      if appender.is_a?(String)
        options[:file_name] = appender
      elsif appender.is_a?(IO)
        options[:io] = appender
      elsif appender.is_a?(Symbol) || appender.is_a?(Subscriber)
        options[:appender] = appender
      else
        options[:logger] = appender
      end
      warn "[DEPRECATED] SemanticLogger.add_appender parameters have changed. Please use: #{options.inspect}"
      options
    end
  end
end
