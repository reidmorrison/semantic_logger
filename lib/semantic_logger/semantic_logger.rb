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
  #   log_level [Symbol]
  #     Optional
  #     By setting the log_level higher than the SemanticLogger::default_level
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
  def self.add_appender(appender, log_level=nil, &block)
    appender_instance = if appender.is_a?(String) || appender.is_a?(IO)
      # $stderr, STDOUT, other IO, or a filename
      SemanticLogger::Appender::File.new(appender, log_level, &block)
    elsif appender.is_a? Appender::Base
      # Already an instance of an appender
      appender.log_level = log_level if log_level
      appender.formatter = block if block
      appender
    else
      # Check if the custom appender responds to all the log levels. For example Ruby ::Logger
      if does_not_implement = LEVELS[1..-1].find{|i| !appender.respond_to?(i)}
        raise "Supplied appender does not implement:#{does_not_implement}. It must implement all of #{LEVELS[1..-1].inspect}"
      end

      raise "Change the log level to #{log_level}, update the log level directly against the supplied appender" if log_level
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

  ############################################################################
  protected

  @@appenders = ThreadSafe::Array.new

  ############################################################################
  private

  # Initial default Level for all new instances of SemanticLogger::Logger
  @@default_level = :info
end