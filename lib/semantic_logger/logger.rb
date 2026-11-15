module SemanticLogger
  # Logger stores the class name to be used for all log messages so that every
  # log message written by this instance will include the class name
  class Logger < Base
    include SemanticLogger::Concerns::Compatibility

    def self.subscribe(object = nil, &block)
      subscriber = block || object

      unless subscriber.is_a?(Proc) || subscriber.respond_to?(:call)
        raise("When supplying an on_log subscriber, it must support the #call method")
      end

      subscribers = (@subscribers ||= Concurrent::Array.new)
      return if subscribers.include?(subscriber)

      subscribers << subscriber
      # A Ractor other than the main one can only call a shareable subscriber.
      if RactorSupport.enabled? && ::Ractor.shareable?(subscriber)
        @ractor_subscribers = [*@ractor_subscribers, subscriber].freeze
      end
      subscribers
    end

    class << self
      attr_reader :subscribers
    end

    # Removes the on_log subscriber.
    def self.unsubscribe(subscriber)
      @subscribers&.delete(subscriber)
      @ractor_subscribers = (@ractor_subscribers - [subscriber]).freeze if @ractor_subscribers
    end

    # Removes every on_log subscriber.
    def self.clear_subscribers
      @subscribers&.clear
      @ractor_subscribers = nil
    end

    # Returns the processor that writes log entries to the appenders, or in a Ractor other than the
    # main one, the RactorProcessor that sends them to the main Ractor.
    def self.processor
      return RactorProcessor.current if RactorSupport.other_ractor?

      @processor ||= Processor.new
    end

    # Switch to the synchronous processor
    def self.sync!
      return if @processor.is_a?(SyncProcessor)

      @processor = SyncProcessor.new(@processor&.appenders)
    end

    # Running without the background logging thread?
    def self.sync?
      processor.is_a?(SyncProcessor)
    end

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
      super
    end

    # Place log request on the queue for the Appender thread to write to each
    # appender in the order that they were registered
    #
    # Subscribers are called inline before handing off to the queue so that
    # they can capture additional context information as needed.
    def log(log, message = nil, progname = nil, &)
      # Compatibility with ::Logger
      return add(log, message, progname, &) unless log.is_a?(SemanticLogger::Log)

      Logger.call_subscribers(log)

      Logger.processor.log(log)
    end

    @processor          = nil
    @subscribers        = nil
    @ractor_subscribers = nil

    # Calls the on_log subscribers, or in a Ractor other than the main one, the shareable ones.
    def self.call_subscribers(log)
      subscribers = RactorSupport.other_ractor? ? @ractor_subscribers : @subscribers
      return unless subscribers

      subscribers.each do |subscriber|
        subscriber.call(log)
      rescue Exception => e
        processor.logger.error("Exception calling :on_log subscriber", e)
      end
    end
  end
end
