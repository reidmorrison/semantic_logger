module SemanticLogger
  # The SyncProcessor performs logging in the current thread.
  #
  # Appenders are designed to only be used by one thread at a time, so all calls
  # are monitor protected in case SyncProcessor is being used in a multi-threaded environment.
  #
  # Ruby does not allow a Monitor to be entered in a signal trap, except without waiting, so a call
  # made in a trap that cannot enter it at once, or that interrupted the thread inside it, which may be
  # in the middle of writing an entry, is left on a queue of pending calls instead (see #exclusively).
  # The next call to enter the monitor first runs the pending ones, in order, and a thread started
  # from the trap enters it to run them, when nothing else does.
  class SyncProcessor
    def add(...)
      @monitor.synchronize { @appenders.add(...) }
    end

    # Logs on the calling thread, which belongs to the application, so a stack overflow while
    # writing (see Appenders#log) is reported rather than raised from the log call.
    #
    # In a signal trap, the entry is written at once when no other call is inside this processor.
    # Otherwise it is written just after, before any entry logged after the trap, and the trap
    # returns without waiting for it.
    def log(log)
      exclusively(wait: false) { write(log) }
    end

    # Returns [Hash] operational statistics for the logging pipeline.
    #
    # In synchronous mode messages are written inline on the calling thread, so the queue holds only
    # the calls made in a signal trap that are still to run (see #log), and no messages are dropped.
    # In a trap it reads them without entering the monitor.
    def stats
      return statistics if TrapSafe.in_trap?

      @monitor.synchronize { statistics }
    end

    # Flush the appenders. In a signal trap, a thread started from it flushes them, after the
    # entries pending, and the trap waits for it, unless the trap interrupted a call inside this
    # processor: the flush then runs just after that call, without waiting (see #exclusively).
    def flush
      exclusively { @appenders.flush }
    end

    # Close the appenders, as for #flush in a signal trap.
    def close
      exclusively { @appenders.close }
    end

    # Remove the appender from those that this processor writes to, and close it, once any log call
    # writing to it has returned. Returns the result of closing it, or nil when it is closed after a
    # signal trap that interrupted a call inside this processor (see #flush).
    #
    # The appenders are reopened on the calling thread (see #reopen), so none is ever waiting to be
    # reopened when it is removed.
    def remove(appender)
      exclusively do
        @appenders.flush if @appenders.delete(appender)
        appender.close
      end
    end

    # Reopen the appenders on the calling thread, or, in a signal trap, as for #flush, so that an
    # appender that connects or locks a Mutex as it reopens can do so.
    def reopen(*args)
      exclusively { @appenders.reopen(*args) }
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
      @pending         = Thread::Queue.new
      @runner          = nil
    end

    def start
      # NOP
    end

    private

    # Runs the block inside the monitor, after the pending calls, and returns its value.
    #
    # A call made by the thread already inside, such as by an appender while it writes, runs at once,
    # as it always has. In a signal trap, where Ruby raises ThreadError for a wait to enter the
    # monitor, a log call (wait: false) runs at once only when it can enter without waiting and no
    # call is pending, and is otherwise left on the queue of pending calls, which a thread started from
    # the trap runs (see #start_runner). A trap that interrupted the thread inside the monitor must not
    # run a call at once, since that thread may be in the middle of writing an entry to an appender,
    # nor wait for it, since that thread does not go on until the trap returns: that thread runs the
    # pending calls before it leaves the monitor, or else the started thread does, just after. Any
    # other call made in a trap waits for the started thread to run it, so that the appenders flush,
    # close, or reopen outside the trap, where they may lock a Mutex of their own, and returns its
    # value.
    def exclusively(wait: true, &)
      if @monitor.mon_owned?
        return @monitor.synchronize(&) unless TrapSafe.in_trap?

        return defer(wait: false, &)
      end
      return defer(wait: true, &) if wait && TrapSafe.in_trap?
      return defer(wait: false, &) unless enter

      begin
        run_pending
        result = yield
        # The calls left meanwhile by a signal trap that interrupted this thread.
        run_pending unless @pending.empty? || TrapSafe.in_trap?
        result
      ensure
        @monitor.exit
      end
    end

    # Enter the monitor and return true, or return false in a signal trap when it cannot be entered
    # without waiting, or when calls are pending, which run first, outside the trap. Tells a trap
    # only then, so that a log call that enters at once does not pay for it.
    def enter
      if @monitor.try_enter
        return true if @pending.empty? || !TrapSafe.in_trap?

        @monitor.exit
        return false
      end
      return false if TrapSafe.in_trap?

      @monitor.enter
      true
    end

    # Leave the block on the queue of pending calls, for a thread started from the signal trap to run.
    # Waits for it to be run, and returns its value, or raises what it raised, or returns nil at once.
    def defer(wait:, &block)
      result = nil
      error  = nil
      @pending << lambda do
        result = block.call
      rescue Exception => e
        error = e
        logger.error("Failed to complete a call made in a signal trap", e) unless wait
      end
      runner = start_runner
      return unless wait

      runner.join
      raise error if error

      result
    end

    # Start a thread that enters the monitor and runs the pending calls, unless one is running.
    # Called in a signal trap, where a Mutex cannot be locked, so it relies on the runner clearing
    # @runner before it checks, inside the monitor, for calls still pending: a call left after that
    # check finds no runner and starts one. Two runners may run at once, rarely, which is harmless.
    def start_runner
      runner = @runner
      return runner if runner&.alive?

      @runner = Thread.new do
        loop do
          finished = @monitor.synchronize do
            run_pending
            @runner = nil
            @pending.empty?
          end
          break if finished
        end
      end
    end

    # Run the calls left by signal traps, in the order they were made. Called inside the monitor.
    def run_pending
      @pending.pop(timeout: 0)&.call until @pending.empty?
    end

    def write(log)
      @processed_count += 1
      @appenders.log(log)
    rescue SystemStackError => e
      @appenders.logger.error("Failed to log a message: the stack overflowed", e)
      false
    end

    def statistics
      {
        queue_size:     @pending.size,
        capped:         false,
        max_queue_size: nil,
        thread_active:  false,
        processed:      @processed_count,
        dropped:        0,
        appenders:      @appenders.stats
      }
    end
  end
end
