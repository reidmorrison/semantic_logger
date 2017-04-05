require 'concurrent'
module SemanticLogger
  # Logger stores the class name to be used for all log messages so that every
  # log message written by this instance will include the class name
  class Logger < Base
    include SemanticLogger::Concerns::Compatibility

    # Returns a Logger instance
    #
    # Return the logger for a specific class, supports class specific log levels
    #   logger = SemanticLogger::Logger.new(self)
    # OR
    #   logger = SemanticLogger::Logger.new('MyClass')
    #
    # Parameters:
    #  klass
    #    A class, module or a string with the application/class name
    #    to be used in the logger
    #
    #  level
    #    The initial log level to start with for this logger instance
    #    Default: SemanticLogger.default_level
    #
    #  filter [Regexp|Proc]
    #    RegExp: Only include log messages where the class name matches the supplied
    #    regular expression. All other messages will be ignored
    #    Proc: Only include log messages where the supplied Proc returns true
    #          The Proc must return true or false
    def initialize(klass, level = nil, filter = nil)
      super(klass, level, filter)
    end

    # Place log request on the queue for the Appender thread to write to each
    # appender in the order that they were registered
    def log(log, message = nil, progname = nil, &block)
      # Compatibility with ::Logger
      return add(log, message, progname, &block) unless log.is_a?(SemanticLogger::Log)
      Processor << log
    end

    # DEPRECATED
    def self.queue_size
      Processor.queue_size
    end

    # DEPRECATED
    def self.flush
      Processor.flush
    end

    # DEPRECATED
    def self.close
      Processor.close
    end

    # DEPRECATED
    def self.logger=(logger)
      Processor.logger = logger
    end

  end
end
