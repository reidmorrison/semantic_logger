require 'thread_safe'

# Logger stores the class name to be used for all log messages so that every
# log message written by this instance will include the class name
module SemanticLogger
  class Logger < Base

    # DO NOT USE. Adding unused formatter to support Rails 4 logging
    # Formatters must be set at the appender level, not at the logger level
    #
    # Due to the following code in Rails::Server#start that cannot be changed
    # without patching the entire method
    #    console = ActiveSupport::Logger.new($stdout)
    #    console.formatter = Rails.logger.formatter
    #    console.level = Rails.logger.level
    #
    #    Rails.logger.extend(ActiveSupport::Logger.broadcast(console))
    attr_accessor :formatter

    # Returns a Logger instance
    #
    # Return the logger for a specific class, supports class specific log levels
    #   logger = SemanticLogger::Logger.new(self)
    # OR
    #   logger = SemanticLogger::Logger.new('MyClass')
    #
    # Parameters:
    #  application
    #    A class, module or a string with the application/class name
    #    to be used in the logger
    #
    #  level
    #    The initial log level to start with for this logger instance
    #    Default: SemanticLogger.default_level
    #
    def initialize(klass, level=nil)
      @name = klass.is_a?(String) ? klass : klass.name
      self.level = level || SemanticLogger.default_level
    end

    # Returns [Integer] the number of log entries that have not been written
    # to the appenders
    #
    # When this number grows it is because the logging appender thread is not
    # able to write to the appenders fast enough. Either reduce the amount of
    # logging, increase the log level, reduce the number of appenders, or
    # look into speeding up the appenders themselves
    def self.queue_size
      queue.size
    end

    # Flush all queued log entries disk, database, etc.
    #  All queued log messages are written and then each appender is flushed in turn
    def self.flush
      return false unless appender_thread_active?

      logger.debug "Flushing appenders with #{queue_size} log messages on the queue"
      reply_queue = Queue.new
      queue << { :command => :flush, :reply_queue => reply_queue }
      reply_queue.pop
    end

    @@lag_check_interval = 5000
    @@lag_threshold_s = 30

    # Returns the check_interval which is the number of messages between checks
    # to determine if the appender thread is falling behind
    def self.lag_check_interval
      @@lag_check_interval
    end

    # Set the check_interval which is the number of messages between checks
    # to determine if the appender thread is falling behind
    def self.lag_check_interval=(lag_check_interval)
      @@lag_check_interval = lag_check_interval
    end

    # Returns the amount of time in seconds
    # to determine if the appender thread is falling behind
    def self.lag_threshold_s
      @@lag_threshold_s
    end

    def self.time_threshold_s=(time_threshold_s)
      @@lag_threshold_s = time_threshold_s
    end

    # Allow the internal logger to be overridden from its default to STDERR
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders
    def self.logger=(logger)
      @@logger = logger
    end

    # DEPRECATED See SemanticLogger.add_appender
    def self.appenders
      warn "[DEPRECATION] `SemanticLogger::Logger.appenders` is deprecated.  Please use `SemanticLogger.add_appender` instead."
      SemanticLogger.appenders
    end

    # DEPRECATED: Please use queue_size instead.
    def self.cache_count
      warn "[DEPRECATION] 'SemanticLogger::Logger.cache_count' is deprecated.  Please use 'SemanticLogger::Logger.queue_size' instead."
      queue_size
    end

    ############################################################################
    protected

    @@appender_thread = nil
    @@queue           = Queue.new

    # Queue to hold messages that need to be logged to the various appenders
    def self.queue
      @@queue
    end

    # Place log request on the queue for the Appender thread to write to each
    # appender in the order that they were registered
    def log(log)
      self.class.queue << log if @@appender_thread
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to STDERR
    def self.logger
      @@logger ||= begin
        l = SemanticLogger::Appender::File.new(STDERR, :warn)
        l.name = self.class.name
        l
      end
    end

    # Start the appender thread
    def self.start_appender_thread
      return false if appender_thread_active?
      @@appender_thread = Thread.new { appender_thread }
      raise "Failed to start Appender Thread" unless @@appender_thread
      true
    end

    # Returns true if the appender_thread is active
    def self.appender_thread_active?
      @@appender_thread && @@appender_thread.alive?
    end

    # Separate appender thread responsible for reading log messages and
    # calling the appenders in it's thread
    def self.appender_thread
      # This thread is designed to never go down unless the main thread terminates
      # Before terminating at_exit is used to flush all the appenders
      #
      # Should any appender fail to log or flush, the exception is logged and
      # other appenders will still be called
      logger.debug "V#{VERSION} Appender thread active"
      begin
        count = 0
        while message = queue.pop
          if message.is_a? Log
            SemanticLogger.appenders.each do |appender|
              begin
                appender.log(message)
              rescue Exception => exc
                logger.error "Appender thread: Failed to log to appender: #{appender.inspect}", exc
              end
            end
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
              SemanticLogger.appenders.each do |appender|
                begin
                  logger.info "Appender thread: Flushing appender: #{appender.name}"
                  appender.flush
                rescue Exception => exc
                  logger.error "Appender thread: Failed to flush appender: #{appender.inspect}", exc
                end
              end

              message[:reply_queue] << true if message[:reply_queue]
              logger.info "Appender thread: All appenders flushed"
            else
              logger.warn "Appender thread: Ignoring unknown command: #{message[:command]}"
            end
          end
        end
      rescue Exception => exception
        # This block may be called after the file handles have been released by Ruby
        begin
          logger.error "Appender thread restarting due to exception", exception
        rescue Exception
          nil
        end
        retry
      ensure
        @@appender_thread = nil
        # This block may be called after the file handles have been released by Ruby
        begin
          logger.debug "Appender thread has stopped"
        rescue Exception
          nil
        end
      end
    end

    # Flush all appenders at exit, waiting for outstanding messages on the queue
    # to be written first
    at_exit do
      flush
    end

    # Start appender thread on load to workaround intermittent startup issues
    # with JRuby 1.8.6 under Trinidad in 1.9 mode
    start_appender_thread
  end
end
