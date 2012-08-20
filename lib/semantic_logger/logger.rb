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
#   SemanticLogger::Manager.register_appender(SemanticLogger::Appender::Logger.new(log))
#
#   logger = SemanticLogger::Logger.new("my.app.class")
#   logger.debug("Login time", :user => 'Joe', :duration => 100, :ip_address=>'127.0.0.1')
#
# # Now log to the Logger above as well as Mongo at the same time
#
#   SemanticLogger::Manager.register_appender(SemanticLogger::Appender::Mongo.new(cfg))
# ...
#   logger.debug("Login time", :user => 'Mary', :duration => 230, :ip_address=>'192.168.0.1')
module SemanticLogger
  class Logger
    include SyncAttr

    # Logging levels in order of precedence
    LEVELS = [:trace, :debug, :info, :warn, :error, :fatal]

    # Mapping of Rails and Ruby Logger levels to SemanticLogger levels
    MAP_LEVELS = []
    ::Logger::Severity.constants.each do |constant|
      MAP_LEVELS[::Logger::Severity.const_get(constant)] = LEVELS.find_index(constant.downcase.to_sym) || LEVELS.find_index(:error)
    end

    # Thread safe Class Attribute accessor for appenders array
    sync_cattr_accessor :appenders do
      []
    end

    # Allow for setting the default log level
    def self.default_level=(default_level)
      @@default_level = default_level
    end

    def self.default_level
      @@default_level
    end

    attr_reader :name, :level

    @@default_level = :info

    # Create a Logger instance
    # Parameters:
    #  application: A class, module or a string with the application/class name
    #               to be used in the logger
    #  options:
    #    :level   The initial log level to start with for this logger instance
    def initialize(klass, options={})
      @name = klass.is_a?(String) ? klass : klass.name
      set_level(options[:level] || self.class.default_level)
    end

    # Set the logging level
    # Must be one of the values in #LEVELS
    def level=(level)
      set_level(level)
    end

    # Implement the log level calls
    #   logger.debug(message|hash|exception, hash|exception=nil, &block)
    #
    # Implement the log level query
    #   logger.debug?
    #
    # Example:
    #   logger = SemanticLogging::Logger.new(self)
    #   logger.debug("Only display this if log level is set to Debug or lower")
    #
    #   # Log semantic information along with a text message
    #   logger.info("Request received", :user => "joe", :duration => 100)
    #
    #   # Log an exception in a semantic way
    #   logger.info("Parsing received XML", exc)
    #
    LEVELS.each_with_index do |level, index|
      class_eval <<-EOT, __FILE__, __LINE__
        def #{level}(message = nil, payload = nil)
          if @level_index <= #{index}
            if block_given? && (result = yield)
              if result.is_a?(String)
                message = message.nil? ? result : "\#{message} -- \#{result.to_s}"
              else
                payload = payload.nil? ? sresult : payload.merge(result)
              end
            end
            self.class.queue << Log.new(:#{level}, self.class.thread_name, name, message, payload, Time.now)
            true
          else
            false
          end
        end

        def #{level}?
          @level_index <= #{index}
        end

        # Log the duration of the supplied block
        #   If an exception occurs in the block the exception is logged using the
        #   same log level. The exception will flow through to the caller unchanged
        def benchmark_#{level}(message, payload = nil)
          raise "Mandatory block missing" unless block_given?
          if @level_index <= #{index}
            start = Time.now
            begin
              result = yield
              self.class.queue << Log.new(:#{level}, self.class.thread_name, name, message, payload, start, Time.now - start)
              result
            rescue Exception => exc
              self.class.queue << Log.new(:#{level}, self.class.thread_name, name, message, exc, start, Time.now - start)
              raise exc
            end
          else
            yield
          end
        end
      EOT
    end

    # Semantic Logging does not support :unknown level since these
    # are not understood by the majority of the logging providers
    # Map it to :error
    alias :unknown :error
    alias :unknown? :error?

    # #TODO implement a thread safe #silence method

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
    def flush
      self.class.flush
    end

    # Flush all pending log entry disk, database, etc.
    #  All pending log writes are completed and each appender is flushed in turn
    def self.flush
      return false unless @@appender_thread.alive?

      reply_queue = Queue.new
      queue << { :command => :flush, :reply_queue => reply_queue }
      reply_queue.pop
    end

    # Internal logger for SymanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to STDERR, replace with another Ruby logger or Rails
    #   logger, but never to SemanticLogger itself
    sync_cattr_accessor :logger do
      require 'logger'
      l = ::Logger.new(STDOUT)
      l.level = ::Logger::INFO
      l
    end

    ############################################################################
    protected

    # Log to queue
    #   Starts the appender thread the first time a logging call is made
    sync_cattr_reader :queue do
      startup
      at_exit { shutdown }
      Queue.new
    end

    Log = Struct.new(:level, :thread_name, :name, :message, :payload, :time, :duration)

    # For JRuby include the Thread name rather than its id
    if defined? Java
      def self.thread_name
        Java::java.lang::Thread.current_thread.name
      end
    else
      def self.thread_name
        Thread.object_id
      end
    end

    # Verify and set the level
    def set_level(level)
      index = if level.is_a?(Integer)
        MAP_LEVELS[level]
      elsif level.is_a?(String)
        level = level.downcase.to_sym
        LEVELS.index(level)
      else
        LEVELS.index(level)
      end

      raise "Invalid level:#{level.inspect} being requested. Must be one of #{LEVELS.inspect}" unless index
      @level_index = index
      @level = level
    end

    # Start a separate appender thread responsible for reading log messages and
    # calling the appenders in it's thread
    def self.startup
      @@appender_thread = Thread.new do
        begin
          # #TODO Logger needs it's own "reliable" appender ;)
          # For example if an appender constantly fails
          # ( bad filename or path, invalid server )
          logger.debug "SemanticLogger::Logger Appender thread started"
          while message=queue.pop
            if message.is_a? Log
              appenders.each {|appender| appender.log(message) }
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

  end
end
