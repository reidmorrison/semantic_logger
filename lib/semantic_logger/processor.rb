module SemanticLogger
  # Thread that submits and processes log requests
  class Processor
    # Returns [Appender::Async => SemanticLogger::Processor] the global instance of this processor
    # wrapped in the Async proxy so that all logging is asynchronous in a thread of its own.
    #
    # More than one instance can be created if needed.
    def self.instance
      @async_appender
    end

    # Start the appender thread
    def self.start
      return false if instance.active?
      instance.thread
      true
    end

    # Returns true if the appender_thread is active
    def self.active?
      instance.alive?
    end

    # Allow the internal logger to be overridden from its default of STDERR
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders
    class << self
      attr_writer :logger
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to STDERR
    def self.logger
      @logger ||= begin
        l      = SemanticLogger::Appender::File.new(io: STDERR, level: :warn)
        l.name = name
        l
      end
    end

    attr_accessor :logger
    attr_reader :appenders

    def initialize
      @logger      = self.class.logger.dup
      @appenders   = Appenders.new
    end

    def log(log)
      appenders.each do |appender|
        begin
          appender.log(log) if appender.should_log?(log)
        rescue Exception => exc
          logger.error "Failed to log to appender: #{appender.inspect}", exc
        end
      end
    end

    def flush
      appenders.each do |appender|
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
      appenders.each do |appender|
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
      appenders.each do |appender|
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

    # TODO: Make max_queue_size configurable.
    @async_appender = Appender::Async.new(appender: new, max_queue_size: -1)
  end
end
