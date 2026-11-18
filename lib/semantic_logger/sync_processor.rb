module SemanticLogger
  # The SyncProcessor performs logging in the current thread.
  #
  # Appenders are designed to only be used by one thread at a time, so all calls
  # are monitor protected in case SyncProcessor is being used in a multi-threaded environment.
  class SyncProcessor
    def add(...)
      @monitor.synchronize { @appenders.add(...) }
    end

    # Logs on the calling thread, which belongs to the application, so a stack overflow while
    # writing (see Appenders#log) is reported rather than raised from the log call.
    def log(...)
      @monitor.synchronize do
        @processed_count += 1
        @appenders.log(...)
      end
    rescue SystemStackError => e
      @appenders.logger.error("Failed to log a message: the stack overflowed", e)
      false
    end

    # Returns [Hash] operational statistics for the logging pipeline.
    #
    # In synchronous mode there is no queue: messages are written inline on the calling
    # thread, so queue_size is always 0 and no messages can be dropped.
    def stats
      @monitor.synchronize do
        {
          queue_size:     0,
          capped:         false,
          max_queue_size: nil,
          thread_active:  false,
          processed:      @processed_count,
          dropped:        0,
          appenders:      @appenders.stats
        }
      end
    end

    def flush
      @monitor.synchronize { @appenders.flush }
    end

    def close
      @monitor.synchronize { @appenders.close }
    end

    # Remove the appender from those that this processor writes to, and close it, once any log call
    # writing to it has returned. Returns the result of closing it.
    #
    # The appenders are reopened on the calling thread (see #reopen), so none is ever waiting to be
    # reopened when it is removed.
    def remove(appender)
      flush if @monitor.synchronize { @appenders.delete(appender) }
      appender.close
    end

    def reopen(*args)
      @monitor.synchronize { @appenders.reopen(*args) }
    end

    # Returns [true|false] whether the calling thread is inside a call to this processor, such as in
    # a signal trap that interrupted a log call. Another thread then waits for that call to return
    # before it can use this processor, so the calling thread must not wait for one that does.
    def current_thread_inside?
      @monitor.mon_owned?
    end

    # Allow the internal logger to be overridden from its default of $stderr
    #   Can be replaced with another Ruby logger or Rails logger, but never to
    #   SemanticLogger::Logger itself since it is for reporting problems
    #   while trying to log to the various appenders (raises ArgumentError)
    #
    # A Ruby or Rails logger is wrapped in an appender (see Appender.internal_logger), so .logger
    # returns that appender.
    def self.logger=(logger)
      @logger = Appender.internal_logger(logger)
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

    # Returns the internal logger of the appenders, for reporting a problem while logging, such as
    # an exception raised by an on_log subscriber. The same logger as the asynchronous Processor's.
    def logger
      @appenders.logger
    end

    def initialize(appenders = nil)
      @monitor         = Monitor.new
      @appenders       = appenders || Appenders.new(self.class.logger.dup)
      @processed_count = 0
    end

    def start
      # NOP
    end
  end
end
