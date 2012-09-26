# Logger is the interface used by
#
# Logger maintains the logging name to be used for all log entries generated
# by the invoking classes or modules
#
# It is recommended to create an instance of the class for every class or
# module so that it can be uniquely identified and searched on
#
# Example, log to Logger:
#   require 'logger'
#   require 'semantic_logger'
#   log = Logger.new(STDOUT)
#   log.level = Logger::DEBUG
#
#   SemanticLogger::Logger.appenders << SemanticLogger::Appender::Logger.new(log)
#
#   logger = SemanticLogger::Logger.new("my.app.class")
#   logger.debug("Login time", :user => 'Joe', :duration => 100, :ip_address=>'127.0.0.1')
#
#   # Now log to the Logger above as well as MongoDB at the same time
#
#   db = Mongodb::Connection.new['production_logging']
#
#   SemanticLogger::Logger.appenders << SemanticLogger::Appender::MongoDB.new(
#     :db              => db,
#     :collection_size => 25.gigabytes
#   )
# ...
#   # This will be logged to both the Ruby Logger and MongoDB
#   logger.debug("Login time", :user => 'Mary', :duration => 230, :ip_address=>'192.168.0.1')
#
module SemanticLogger
  class Logger < Base
    include SyncAttr

    # Thread safe Class Attribute accessor for appenders array
    sync_cattr_accessor :appenders do
      []
    end

    # Initial default Level for all new instances of SemanticLogger::Logger
    @@default_level = :info

    # Allow for setting the global default log level
    # This change only applies to _new_ loggers, existing logger levels
    # will not be changed in any way
    def self.default_level=(level)
      @@default_level = level
    end

    # Returns the global default log level for new Logger instances
    def self.default_level
      @@default_level
    end

    attr_reader :name

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
    #    Default: SemanticLogger::Logger.default_level
    #
    def initialize(klass, level=nil)
      @name = klass.is_a?(String) ? klass : klass.name
      self.level = level || self.class.default_level
    end

    # Returns [Integer] the number of log entries that have not been written
    # to the appenders
    #
    # When this number grows it is because the logging appender thread is not
    # able to write to the appenders fast enough. Either reduce the amount of
    # logging, increase the log level, reduce the number of appenders, or
    # look into speeding up the appenders themselves
    def self.cache_count
      queue.size
    end

    # Flush all pending log entry disk, database, etc.
    #  All pending log writes are completed and each appender is flushed in turn
    def self.flush
      return false unless @@appender_thread.alive?

      reply_queue = Queue.new
      queue << { :command => :flush, :reply_queue => reply_queue }
      reply_queue.pop
    end

    @@lag_check_interval = 1000
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

    ############################################################################
    protected

    # Place log request on the queue for the Appender thread to write to each
    # appender in the order that they were registered
    def log(log)
      self.class.queue << log
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to STDERR
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself
    #
    # Warning: Do not use this logger directly it is intended for internal logging
    #          within Semantic Logger itself
    sync_cattr_accessor :logger do
      SemanticLogger::Appender::File.new(STDERR, :warn)
    end

    # Log to queue
    #   Starts the appender thread the first time a logging call is made
    sync_cattr_reader :queue do
      startup
      at_exit { shutdown }
      Queue.new
    end

    # Start a separate appender thread responsible for reading log messages and
    # calling the appenders in it's thread
    def self.startup
      @@appender_thread = Thread.new do
        begin
          logger.debug "SemanticLogger::Logger Appender thread started"
          count = 0
          while message=queue.pop
            if message.is_a? Log
              appenders.each {|appender| appender.log(message) }
              count += 1
              # Check every few log messages whether this appender thread is falling behind
              if count > lag_check_interval
                if (diff = Time.now - message.time) > lag_threshold_s
                  logger.warn "SemanticLogger::Logger Appender thread has fallen behind by #{diff} seconds with #{cache_count} messages queued up. Consider reducing the log level or changing the appenders"
                end
                count = 0
              end
            else
              case message[:command]
              when :shutdown
                appenders.each {|appender| appender.flush }
                message[:reply_queue] << true
                logger.debug "SemanticLogger::Logger appenders flushed, now shutting down"
                break
              when :flush
                appenders.each {|appender| appender.flush }
                message[:reply_queue] << true
                logger.debug "SemanticLogger::Logger appenders flushed"
              end
            end
          end
        rescue Exception => exception
          logger.error "SemanticLogger::Logger Appender thread restarting due to exception: #{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
          # Start a new appender thread and let this one terminate
          startup
        ensure
          logger.debug "SemanticLogger::Logger Appender thread stopped"
        end
      end
    end

    # Stop the log appender thread and flush all appenders
    def self.shutdown
      return false unless @@appender_thread.alive?

      logger.debug "SemanticLogger::Logger Shutdown. Stopping appender thread"
      reply_queue = Queue.new
      queue << { :command => :shutdown, :reply_queue => reply_queue }
      result = reply_queue.pop
      # Undefine the class variable for the queue since in test environments
      # at_exit can be invoked multiple times
      remove_class_variable(:@@queue)
      result
    end

    # Formatting does not occur within this thread, it is done by each appender
    # in the appender thread
    def default_formatter
      nil
    end

  end
end
