module SemanticLogger
  # The SyncProcessor performs logging in the current thread.
  #
  # Appenders are designed to only be used by one thread at a time, so all calls
  # are monitor protected in case SyncProcessor is being used in a multi-threaded environment.
  class SyncProcessor
    def add(*args, &block)
      @monitor.synchronize { @appenders.add(*args, &block) }
    end

    def log(*args, &block)
      @monitor.synchronize { @appenders.log(*args, &block) }
    end

    def flush
      @monitor.synchronize { @appenders.flush }
    end

    def close
      @monitor.synchronize { @appenders.close }
    end

    def reopen(*args)
      @monitor.synchronize { @appenders.reopen(*args) }
    end

    # Allow the internal logger to be overridden from its default of $stderr
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders
    class << self
      attr_writer :logger
    end

    # Internal logger for SemanticLogger
    #   For example when an appender is not working etc..
    #   By default logs to $stderr
    def self.logger
      @logger ||=
        begin
          l      = SemanticLogger::Appender::IO.new($stderr, level: :warn)
          l.name = name
          l
        end
    end

    attr_reader :appenders

    def initialize(appenders = nil)
      @monitor   = Monitor.new
      @appenders = appenders || Appenders.new(self.class.logger.dup)
    end

    def start
      # NOP
    end
  end
end
