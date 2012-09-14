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
#   db = Mongo::Connection.new['production_logging']
#
#   SemanticLogger::Logger.appenders << SemanticLogger::Appender::MongoDB.new(
#     :db              => db,
#     :collection_size => 25.gigabytes
#   )
# ...
#   # This will be logged to both the Ruby Logger and MongoDB
#   logger.debug("Login time", :user => 'Mary', :duration => 230, :ip_address=>'192.168.0.1')
#
require 'logger'
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

    # Allow for setting the global default log level
    # This change only applies to _new_ loggers, existing logger levels
    # will not be changed in any way
    def self.level=(level)
      @@level = level
    end

    # Returns the global default log level for new Logger instances
    def self.level
      @@level
    end

    attr_reader :name, :level

    @@level = :info

    # Returns a Logger instance
    #
    # Return the logger for a specific class, supports class specific log levels
    #   logger = SemanticLogger::Logger.new(self)
    # OR
    #   logger = SemanticLogger::Logger.new('MyClass')
    #
    # Parameters:
    #  application: A class, module or a string with the application/class name
    #               to be used in the logger
    #  options:
    #    :level   The initial log level to start with for this logger instance
    def initialize(klass, options={})
      @name = klass.is_a?(String) ? klass : klass.name
      set_level(options[:level] || self.class.level)
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
                payload = payload.nil? ? result : payload.merge(result)
              end
            end
            # Add scoped payload
            if self.payload
              payload = payload.nil? ? self.payload : self.payload.merge(payload)
            end
            self.class.queue << Log.new(:#{level}, self.class.thread_name, name, message, payload, Time.now, nil, tags)
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
              end_time = Time.now
              # Add scoped payload
              if self.payload
                payload = payload.nil? ? self.payload : self.payload.merge(payload)
              end
              self.class.queue << Log.new(:#{level}, self.class.thread_name, name, message, payload, end_time, 1000.0 * (end_time - start), tags)
              result
            rescue Exception => exc
              # TODO Need to be able to have both an exception and a Payload
              self.class.queue << Log.new(:#{level}, self.class.thread_name, name, message, exc, Time.now, 1000.0 * (Time.now - start), tags)
              raise exc
            end
          else
            yield
          end
        end
      EOT
    end

    # Add the supplied tags to the list of tags to log for this thread whilst
    # the supplied block is active
    # Returns nil if no tags are currently set
    def with_tags(*tags)
      current_tags = self.tags
      # Check for nil tags
      if tags
        Thread.current[:semantic_logger_tags] = current_tags ? current_tags + tags : tags
      end
      yield
    ensure
      Thread.current[:semantic_logger_tags] = current_tags
    end

    # Returns [Array] of [String] tags currently active for this thread
    # Returns nil if no tags are set
    def tags
      Thread.current[:semantic_logger_tags]
    end

    # Thread specific context information to be logged with every log entry
    #
    # Add a payload to all log calls on This Thread within the supplied block
    #
    #   logger.with_payload(:tracking_number=>12345) do
    #     logger.debug('Hello World')
    #   end
    #
    # If a log call already includes a pyload, this payload will be merged with
    # the supplied payload, with the supplied payload taking precedence
    #
    #   logger.with_payload(:tracking_number=>12345) do
    #     logger.debug('Hello World', :result => 'blah')
    #   end
    def with_payload(payload)
      current_payload = self.payload
      Thread.current[:semantic_logger_payload] = current_payload ? current_payload.merge(payload) : payload
      yield
    ensure
      Thread.current[:semantic_logger_payload] = current_payload
    end

    # Returns [Hash] payload to be added to every log entry in the current scope
    # on this thread.
    # Returns nil if no payload is currently set
    def payload
      Thread.current[:semantic_logger_payload]
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
    def self.flush
      return false unless @@appender_thread.alive?

      reply_queue = Queue.new
      queue << { :command => :flush, :reply_queue => reply_queue }
      reply_queue.pop
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to STDERR, replace with another Ruby logger or Rails
    #   logger, but never to SemanticLogger itself
    #
    # Warning: Do not use this logger directly it is intended for internal logging
    #          within Semantic Logger itself
    sync_cattr_accessor :logger do
      l = ::Logger.new(STDERR)
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

    # Struct Log
    #
    # level
    #   Log level of the supplied log call
    #   :trace, :debug, :info, :warn, :error, :fatal
    #
    # thread_name
    #   Name of the thread in which the logging call was called
    #
    # name
    #   Class name supplied to the logging instance
    #
    # message
    #   Text message to be logged
    #
    # payload
    #   Optional Hash or Ruby Exception object to be logged
    #
    # time
    #   The time at which the log entry was created
    #
    # duration
    #   The time taken to complete a benchmark call
    #
    # tags
    #   Any tags active on the thread when the log call was made
    #
    Log = Struct.new(:level, :thread_name, :name, :message, :payload, :time, :duration, :tags)

    # For JRuby include the Thread name rather than its id
    if defined? Java
      def self.thread_name
        Java::java.lang::Thread.current_thread.name
      end
    else
      def self.thread_name
        Thread.current.object_id
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
