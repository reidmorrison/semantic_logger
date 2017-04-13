module SemanticLogger
  # Thread that submits and processes log requests
  class Processor
    # Start the appender thread
    def self.start
      return false if active?
      @thread = Thread.new { process_requests }
      raise 'Failed to start Appender Thread' unless @thread
      true
    end

    # Returns true if the appender_thread is active
    def self.active?
      @thread && @thread.alive?
    end

    # Returns [Integer] the number of log entries waiting to be written to the appenders.
    #
    # When this number grows it is because the logging appender thread is not
    # able to write to the appenders fast enough. Either reduce the amount of
    # logging, increase the log level, reduce the number of appenders, or
    # look into speeding up the appenders themselves
    def self.queue_size
      queue.size
    end

    # Flush all queued log entries disk, database, etc.
    #  All queued log messages are written and then each appender is flushed in turn.
    def self.flush
      submit_request(:flush)
    end

    # Close all appenders and flush any outstanding messages.
    def self.close
      submit_request(:close)
    end

    # Add log request to the queue for processing.
    def self.<<(log)
      return unless active?

      call_log_subscribers(log)
      queue << log
    end

    # Submit command and wait for reply
    def self.submit_request(command)
      return false unless active?

      msg = "Too many queued log messages: #{queue_size}, running command: #{command}"
      if queue_size > 1_000
        logger.warn msg
      elsif queue_size > 100
        logger.info msg
      elsif queue_size > 0
        logger.trace msg
      end

      reply_queue = Queue.new
      queue << {command: command, reply_queue: reply_queue}
      reply_queue.pop
    end

    # Allow the internal logger to be overridden from its default of STDERR
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders
    def self.logger=(logger)
      @logger = logger
    end

    # Returns the check_interval which is the number of messages between checks
    # to determine if the appender thread is falling behind
    def self.lag_check_interval
      @lag_check_interval
    end

    # Set the check_interval which is the number of messages between checks
    # to determine if the appender thread is falling behind
    def self.lag_check_interval=(lag_check_interval)
      @lag_check_interval = lag_check_interval
    end

    # Returns the amount of time in seconds
    # to determine if the appender thread is falling behind
    def self.lag_threshold_s
      @lag_threshold_s
    end

    def self.on_metric(options = {}, &block)
      # Backward compatibility
      options    = options.is_a?(Hash) ? options.dup : {appender: options}
      subscriber = block || options.delete(:appender)

      # Convert symbolized metrics appender to an actual object
      subscriber = SemanticLogger::Appender.constantize_symbol(subscriber, 'SemanticLogger::Metrics').new(options) if subscriber.is_a?(Symbol)

      raise('When supplying a metrics subscriber, it must support the #call method') unless subscriber.is_a?(Proc) || subscriber.respond_to?(:call)
      subscribers = (@metric_subscribers ||= Concurrent::Array.new)
      subscribers << subscriber unless subscribers.include?(subscriber)
    end

    def self.on_log(object = nil, &block)
      subscriber = block || object

      raise('When supplying an on_log subscriber, it must support the #call method') unless subscriber.is_a?(Proc) || subscriber.respond_to?(:call)
      subscribers = (@log_subscribers ||= Concurrent::Array.new)
      subscribers << subscriber unless subscribers.include?(subscriber)
    end

    private

    @thread             = nil
    @queue              = Queue.new
    @lag_check_interval = 5000
    @lag_threshold_s    = 30
    @metric_subscribers = nil
    @log_subscribers    = nil

    # Queue to hold messages that need to be logged to the various appenders
    def self.queue
      @queue
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

    # Separate appender thread responsible for reading log messages and
    # calling the appenders in it's thread
    def self.process_requests
      # This thread is designed to never go down unless the main thread terminates
      # Before terminating at_exit is used to flush all the appenders
      #
      # Should any appender fail to log or flush, the exception is logged and
      # other appenders will still be called
      Thread.current.name = 'SemanticLogger::Processor'
      logger.trace "V#{VERSION} Processor thread active"
      begin
        count = 0
        while message = queue.pop
          if message.is_a?(Log)
            call_appenders(message)
            call_metric_subscribers(message) if message.metric
            count += 1
            # Check every few log messages whether this appender thread is falling behind
            if count > lag_check_interval
              if (diff = Time.now - message.time) > lag_threshold_s
                logger.warn "Appender thread has fallen behind by #{diff} seconds with #{queue_size} messages queued up. Consider reducing the log level or changing the appenders"
              end
              count = 0
            end
          else
            case message[:command]
            when :flush
              flush_appenders
              message[:reply_queue] << true if message[:reply_queue]
            when :close
              close_appenders
              message[:reply_queue] << true if message[:reply_queue]
              break
            else
              logger.warn "Appender thread: Ignoring unknown command: #{message[:command]}"
            end
          end
        end
      rescue Exception => exception
        # This block may be called after the file handles have been released by Ruby
        begin
          logger.error 'Appender thread restarting due to exception', exception
        rescue Exception
          nil
        end
        retry
      ensure
        @thread = nil
        # This block may be called after the file handles have been released by Ruby
        begin
          logger.trace 'Appender thread has stopped'
        rescue Exception
          nil
        end
      end
    end

    # Call Metric subscribers
    def self.call_metric_subscribers(log)
      # If no subscribers registered, then return immediately
      return unless @metric_subscribers

      @metric_subscribers.each do |subscriber|
        begin
          subscriber.call(log)
        rescue Exception => exc
          logger.error 'Exception calling metrics subscriber', exc
        end
      end
    end

    # Call on_log subscribers
    def self.call_log_subscribers(log)
      # If no subscribers registered, then return immediately
      return unless @log_subscribers

      @log_subscribers.each do |subscriber|
        begin
          subscriber.call(log)
        rescue Exception => exc
          logger.error 'Exception calling :on_log subscriber', exc
        end
      end
    end

    # Call Appenders
    def self.call_appenders(log)
      SemanticLogger.appenders.each do |appender|
        begin
          appender.log(log)
        rescue Exception => exc
          logger.error "Appender thread: Failed to log to appender: #{appender.inspect}", exc
        end
      end
    end

    def self.flush_appenders
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

    def self.close_appenders
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

  end
end
