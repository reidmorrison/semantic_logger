module SemanticLogger
  # Thread that submits and processes log requests
  class Processor
    # Returns [Appender::Async => SemanticLogger::Processor] the global instance of this processor
    # wrapped in the Async Facade so that all logging is asynchronous in a thread of its own.
    #
    # More than one instance can be created if needed.
    def self.instance
      @processor
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

    # Returns [Integer] the number of log entries waiting to be written to the appenders.
    #
    # When this number grows it is because the logging appender thread is not
    # able to write to the appenders fast enough. Either reduce the amount of
    # logging, increase the log level, reduce the number of appenders, or
    # look into speeding up the appenders themselves
    def self.queue_size
      instance.queue.size
    end

    # Add log request to the queue for processing.
    # Log subscribers are called inline before handing off to the queue.
    def self.<<(log)
      instance.appender.send(:call_log_subscribers, log)
      instance.log(log)
    end

    # Returns the check_interval which is the number of messages between checks
    # to determine if the appender thread is falling behind.
    def self.lag_check_interval
      instance.lag_check_interval
    end

    # Set the check_interval which is the number of messages between checks
    # to determine if the appender thread is falling behind.
    def self.lag_check_interval=(lag_check_interval)
      instance.lag_check_interval = lag_check_interval
    end

    # Returns the amount of time in seconds
    # to determine if the appender thread is falling behind.
    def self.lag_threshold_s
      instance.lag_threshold_s
    end

    # Allow the internal logger to be overridden from its default of STDERR
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders
    def self.logger=(logger)
      @logger = logger
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

    attr_accessor :logger, :log_subscribers

    def initialize
      @log_subscribers = nil
      @logger          = self.class.logger.dup
      @logger.name     = self.class.name
    end

    def on_log(object = nil, &block)
      subscriber = block || object

      raise('When supplying an on_log subscriber, it must support the #call method') unless subscriber.is_a?(Proc) || subscriber.respond_to?(:call)
      subscribers = (@log_subscribers ||= Concurrent::Array.new)
      subscribers << subscriber unless subscribers.include?(subscriber)
    end

    def log(log)
      SemanticLogger.appenders.each do |appender|
        begin
          appender.log(log) if appender.should_log?(log)
        rescue Exception => exc
          logger.error "Appender thread: Failed to log to appender: #{appender.inspect}", exc
        end
      end
    end

    def flush
      SemanticLogger.appenders.each do |appender|
        begin
          logger.trace "Appender thread: Flushing appender: #{appender.name}"
          appender.flush
        rescue Exception => exc
          logger.error "Appender thread: Failed to flush appender: #{appender.inspect}", exc
        end
      end
      logger.trace 'Appender thread: All appenders flushed'
    end

    def close
      SemanticLogger.appenders.each do |appender|
        begin
          logger.trace "Appender thread: Closing appender: #{appender.name}"
          appender.flush
          appender.close
          SemanticLogger.remove_appender(appender)
        rescue Exception => exc
          logger.error "Appender thread: Failed to close appender: #{appender.inspect}", exc
        end
      end
      logger.trace 'Appender thread: All appenders closed and removed from appender list'
    end

    private

    @processor = Appender::Async.new(name: 'SemanticLogger::Processor', max_queue_size: -1, appender: new)

    # Call on_log subscribers
    def call_log_subscribers(log)
      # If no subscribers registered, then return immediately
      return unless log_subscribers

      log_subscribers.each do |subscriber|
        begin
          subscriber.call(log)
        rescue Exception => exc
          logger.error 'Exception calling :on_log subscriber', exc
        end
      end
    end

  end
end
