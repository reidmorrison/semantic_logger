require 'thread_safe'
module SemanticLogger
  # Logging levels in order of most detailed to most severe
  LEVELS = [:trace, :debug, :info, :warn, :error, :fatal]

  # Return a logger for the supplied class or class_name
  def self.[](klass)
    SemanticLogger::Logger.new(klass)
  end

  # Allow for setting the global default log level
  # This change only applies to _new_ loggers, existing logger levels
  # will not be changed in any way
  def self.default_level=(level)
    @@default_level = level
    # For performance reasons pre-calculate the level index
    @@default_level_index = level_to_index(level)
  end

  # Returns the global default log level for new Logger instances
  def self.default_level
    @@default_level
  end

  # Add a new logging appender as a new destination for all log messages
  # emitted from Semantic Logger
  #
  # Appenders will be written to in the order that they are added
  #
  # If a block is supplied then it will be used to customize the format
  # of the messages sent to that appender. See SemanticLogger::Logger.new for
  # more information on custom formatters
  #
  # Parameters
  #   appender [String|IO|SemanticLogger::Appender::Base|::Logger]
  #     Filename to write log messages to
  #        Or,
  #     STDOUT, STDERR, or any IO stream to write log messages to
  #        Or,
  #     Any SemanticLogger::Appender instance such as
  #       SemanticLogger::Appender::File
  #       SemanticLogger::Appender::Wrapper
  #       SemanticLogger::Appender::Mongodb
  #        Or,
  #     A custom appender derived from SemanticLogger::Appender::Base
  #        Or,
  #     Ruby built-in Logger, or any logger that implements the following methods:
  #       :debug, :info, :warn, :error, :fatal
  #
  #   level [Symbol]
  #     Optional
  #     By setting the level higher than the SemanticLogger::default_level
  #     this appender can exclude lower level log messages
  #     Any one of SemanticLogger::LEVELS. For example: :trace, :debug, :info, :warn, :error, :fatal
  #
  # Examples:
  #
  #   # Send all logging output to Standard Out (Screen)
  #   SemanticLogger.add_appender(STDOUT)
  #
  #   # Send all logging output to a file
  #   SemanticLogger.add_appender('logfile.log')
  #
  #   # Send all logging output to a file and only :info and above to standard output
  #   SemanticLogger.add_appender('logfile.log')
  #   SemanticLogger.add_appender(STDOUT, :info)
  #
  # Log to an existing logger:
  #
  #   # Send Semantic logging output to an existing logger
  #   require 'logger'
  #   require 'semantic_logger'
  #
  #   # Built-in Ruby logger
  #   log = Logger.new(STDOUT)
  #   log.level = Logger::DEBUG
  #
  #   SemanticLogger.default_level = :debug
  #   SemanticLogger.add_appender(log)
  #
  #   logger = SemanticLogger['Example']
  #   logger.info "Hello World"
  #   logger.debug("Login time", :user => 'Joe', :duration => 100, :ip_address=>'127.0.0.1')
  #
  def self.add_appender(appender, level=nil, &block)
    appender_instance = if appender.is_a?(String) || appender.is_a?(IO)
      # $stderr, STDOUT, other IO, or a filename
      SemanticLogger::Appender::File.new(appender, level, &block)
    elsif appender.is_a? Appender::Base
      # Already an instance of an appender
      appender.level = level if level
      appender.formatter = block if block
      appender
    else
      # Check if the custom appender responds to all the log levels. For example Ruby ::Logger
      if does_not_implement = LEVELS[1..-1].find{|i| !appender.respond_to?(i)}
        raise "Supplied appender does not implement:#{does_not_implement}. It must implement all of #{LEVELS[1..-1].inspect}"
      end

      raise "Change the log level to #{level}, update the log level directly against the supplied appender" if level
      SemanticLogger::Appender::Wrapper.new(appender, &block)
    end
    @@appenders << appender_instance

    # Start appender thread if it is not already running
    SemanticLogger::Logger.start_appender_thread

    appender_instance
  end

  # Remove an existing appender
  # Currently only supports appender instances
  def self.remove_appender(appender)
    @@appenders.delete(appender)
  end

  # Returns [SemanticLogger::Appender::Base] a copy of the list of active
  # appenders for debugging etc.
  # Use SemanticLogger.add_appender and SemanticLogger.remove_appender
  # to manipulate the active appenders list
  def self.appenders
    @@appenders.clone
  end

  # Wait until all queued log messages have been written and flush all active
  # appenders
  def self.flush
    SemanticLogger::Logger.flush
  end

  # After forking an active process call SemanticLogger.reopen to re-open
  # any open file handles etc to resources
  #
  # Note: Only appenders that implement the reopen method will be called
  def self.reopen
    @@appenders.each {|appender| appender.reopen if appender.respond_to?(:reopen)}
    # After a fork the appender thread is not running, start it if it is not running
    SemanticLogger::Logger.start_appender_thread
  end

  # Supply a block to be called whenever a metric is seen during benchmark logging
  #
  #  Parameters
  #    block
  #      The block to be called
  #
  # Example:
  #   SemanticLogger.on_metric do |log_struct|
  #     puts "#{log_struct.metric} was received. Log Struct: #{log_struct.inspect}"
  #   end
  def self.on_metric(&block)
    SemanticLogger::Logger.on_metric(&block)
  end

  # Add signal handlers for Semantic Logger
  #
  # Two signal handlers will be registered by default:
  #
  # 1. Changing the log_level:
  #
  #   The log level can be changed without restarting the process by sending the
  #   log_level_signal, which by default is 'USR2'
  #
  #   When the log_level_signal is raised on this process, the global default log level
  #   rotates through the following log levels in the following order, starting
  #   from the current global default level:
  #     :warn, :info, :debug, :trace
  #
  #   If the current level is :trace it wraps around back to :warn
  #
  # 2. Logging a Ruby thread dump
  #
  #   When the signal is raised on this process, Semantic Logger will write the list
  #   of threads to the log file, along with their back-traces when available
  #
  #   For JRuby users this thread dump differs form the standard QUIT triggered
  #   Java thread dump which includes system threads and Java stack traces.
  #
  #   It is recommended to name any threads you create in the application, by
  #   calling the following from within the thread itself:
  #      Thread.current.name = 'My Worker'
  #
  # Also adds JRuby Garbage collection logging so that any garbage collections
  # that exceed the time threshold will be logged. Default: 100 ms
  # Currently only supported when running JRuby
  #
  # Note:
  #   To only register one of the signal handlers, set the other to nil
  #   Set gc_log_microseconds to nil to not enable JRuby Garbage collections
  def self.add_signal_handler(log_level_signal='USR2', thread_dump_signal='TTIN', gc_log_microseconds=100000)
    Signal.trap(log_level_signal) do
      index = (default_level == :trace) ? LEVELS.find_index(:error) : LEVELS.find_index(default_level)
      new_level = LEVELS[index-1]
      self['SemanticLogger'].warn "Changed global default log level to #{new_level.inspect}"
      self.default_level = new_level
    end if log_level_signal

    Signal.trap(thread_dump_signal) do
      logger = SemanticLogger['Thread Dump']
      Thread.list.each do |thread|
        next if thread == Thread.current
        message = thread.name
        if backtrace = thread.backtrace
          message += "\n"
          message << backtrace.join("\n")
        end
        tags = thread[:semantic_logger_tags]
        tags = tags.nil? ? [] : tags.clone
        logger.tagged(tags) { logger.warn(message) }
      end
    end if thread_dump_signal

    if gc_log_microseconds && defined?(JRuby)
      listener = SemanticLogger::JRuby::GarbageCollectionLogger.new(gc_log_microseconds)
      Java::JavaLangManagement::ManagementFactory.getGarbageCollectorMXBeans.each do |gcbean|
        gcbean.add_notification_listener(listener, nil, nil)
      end
    end

    true
  end

  ############################################################################
  protected

  @@appenders = ThreadSafe::Array.new

  ############################################################################
  private

  def self.default_level_index
    Thread.current[:semantic_logger_silence] || @@default_level_index
  end

  # Returns the symbolic level for the supplied level index
  def index_to_level(level_index)
    LEVELS[level_index]
  end

  # Internal method to return the log level as an internal index
  # Also supports mapping the ::Logger levels to SemanticLogger levels
  def self.level_to_index(level)
    return if level.nil?

    index = if level.is_a?(Symbol)
      LEVELS.index(level)
    elsif level.is_a?(String)
      level = level.downcase.to_sym
      LEVELS.index(level)
    elsif level.is_a?(Integer) && defined?(::Logger::Severity)
      # Mapping of Rails and Ruby Logger levels to SemanticLogger levels
      @@map_levels ||= begin
        levels = []
        ::Logger::Severity.constants.each do |constant|
          levels[::Logger::Severity.const_get(constant)] = LEVELS.find_index(constant.downcase.to_sym) || LEVELS.find_index(:error)
        end
        levels
      end
      @@map_levels[level]
    end
    raise "Invalid level:#{level.inspect} being requested. Must be one of #{LEVELS.inspect}" unless index
    index
  end

  # Initial default Level for all new instances of SemanticLogger::Logger
  @@default_level = :info
  @@default_level_index = level_to_index(@@default_level)
end
