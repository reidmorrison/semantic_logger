require "semantic_logger/metric/processor_methods"

module SemanticLogger
  # The SyncProcessor performs logging in the current thread.
  #
  # Appenders are designed to only be used by one thread at a time, so all calls
  # are monitor protected in case SyncProcessor is being used in a multi-threaded environment.
  #
  # Ruby does not allow a Monitor to be entered in a signal trap, so another thread runs a call made
  # in a trap. A log entry is left on a queue of pending calls, which whoever next enters the monitor
  # runs first, in order, and a thread started from the trap enters it to do so when nothing else does
  # (see #defer). Every other call runs on a thread that the trap starts and waits for, at most
  # TRAP_WAIT_SECONDS (see #outside_trap). Neither ever runs on the trap's thread, so that an appender
  # can lock a Mutex of its own as it writes, flushes, closes, or reopens, as a Ruby Logger does.
  class SyncProcessor
    include Metric::ProcessorMethods

    # Seconds that a call other than a log call, such as a flush or a reopen, waits in a signal trap
    # for the thread that runs it. It may need a lock that the thread the trap interrupted holds.
    TRAP_WAIT_SECONDS = 1

    # Returned by #exclusively, which does not run its block, in a signal trap.
    TRAPPED = Object.new.freeze
    private_constant :TRAPPED

    # Add an appender. In a signal trap, as for #flush, which returns nil instead of the appender when
    # it is not added in time. SemanticLogger.add_appender adds to the appenders directly instead.
    def add(**args, &block)
      appender = synchronize { @appenders.add(**args, &block) }
      Metric.collector.start if appender&.metrics_interval
      appender
    end

    # Gives the snapshot of metrics to the metric appenders on the calling thread (see
    # Appenders#log_metrics), or, in a signal trap, as for #log, just after, on another thread.
    def log_metrics(snapshot)
      logged = exclusively { @appenders.log_metrics(snapshot) }
      return logged unless logged.equal?(TRAPPED)

      defer { @appenders.log_metrics(snapshot) }
      true
    rescue SystemStackError => e
      @appenders.logger.error("Failed to write metrics: the stack overflowed", e)
      false
    end

    # Logs on the calling thread, which belongs to the application, so a stack overflow while
    # writing (see Appenders#log) is reported rather than raised from the log call.
    #
    # In a signal trap, the entry is written just after, by another thread, before any entry logged
    # after the trap, and the trap returns without waiting for it (see #defer).
    def log(log)
      logged = exclusively { write(log) }
      return logged unless logged.equal?(TRAPPED)

      defer { write(log) }
      true
    rescue SystemStackError => e
      @appenders.logger.error("Failed to log a message: the stack overflowed", e)
      false
    end

    # Returns [Hash] operational statistics for the logging pipeline.
    #
    # In synchronous mode messages are written inline on the calling thread, so the queue holds only
    # the entries logged in a signal trap that are still to be written (see #log), and no messages
    # are dropped. In a trap it reads them without entering the monitor.
    def stats
      stats = exclusively { statistics }
      stats.equal?(TRAPPED) ? statistics : stats
    end

    # Returns [Hash] the cumulative counts of the log entries written since startup: processed:, and
    # dropped:, always 0, as for #stats. Never enters the monitor. Read for Semantic Logger's own
    # metrics (see Metric::InternalMetrics).
    def queue_log_counts
      {processed: @processed_count, dropped: 0}
    end

    # Flush the appenders. In a signal trap, a thread that the trap starts flushes them, after the
    # entries logged in the trap before, and the trap waits for it, at most TRAP_WAIT_SECONDS, then
    # returns its result, or raises what it raised. When it has not finished by then, such as when the
    # trap interrupted a call inside this processor, which cannot return before the trap does, it
    # returns nil and the flush runs just after.
    def flush
      synchronize { @appenders.flush }
    end

    # Close the appenders, as for #flush in a signal trap.
    #
    # A stack overflow while closing is reported rather than raised, as by #log, since the calling
    # thread belongs to the application, even when Appenders#close raises it, for the asynchronous
    # Processor to move to a new thread.
    def close
      synchronize do
        @appenders.close
      rescue SystemStackError => e
        logger.error("Failed to close the appenders: the stack overflowed", e)
        nil
      end
    end

    # Remove the appender from those that this processor writes to, and close it, once any log call
    # writing to it has returned. Closes it after leaving the monitor, so that the other threads
    # can log meanwhile. Returns the result of closing it, or, in a signal trap, as for #flush, nil
    # when it is not closed in time.
    #
    # The appenders are reopened on the calling thread (see #reopen), so none is ever waiting to be
    # reopened when it is removed.
    def remove(appender)
      removed = exclusively { @appenders.flush if @appenders.delete(appender) }
      return outside_trap { remove(appender) } if removed.equal?(TRAPPED)

      appender.close
    end

    # Reopen the appenders on the calling thread, or, in a signal trap, as for #flush, so that an
    # appender that connects or locks a Mutex as it reopens can do so.
    def reopen(*args)
      synchronize { @appenders.reopen(*args) }
    end

    # Returns [Integer] the number of entries logged in a signal trap that are still to be written
    # (see #log), the only ones that wait in synchronous mode. Never enters the monitor.
    def queue_size
      pending_count
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
      @pid             = Process.pid
    end

    def start
      # NOP
    end

    private

    # Runs the block inside the monitor, after the pending calls, and returns its value, or returns
    # TRAPPED, without running it, in a signal trap. Leaves the monitor even when a pending call
    # raises past its rescue, such as Timeout or Thread#raise, so that no other thread waits for ever.
    #
    # A call made by the thread already inside, such as by an appender while it writes, runs at once,
    # as it always has, without the pending calls, which may write to the appender in the middle of
    # its write. Monitor#enter raises ThreadError in a trap, even when no other thread is inside, so
    # it tells a trap without a check of its own, except when the trap interrupted the thread inside,
    # which the monitor lets in again. The thread inside runs the calls that such a trap left before
    # it leaves the monitor. Monitor#enter also raises ThreadError outside a trap, for a fiber when
    # another fiber of its thread is inside, which is raised again, as before.
    def exclusively
      if @monitor.mon_owned?
        return TRAPPED if TrapSafe.in_trap?

        return yield
      end

      begin
        @monitor.enter
      rescue ThreadError
        raise unless TrapSafe.in_trap?

        return TRAPPED
      end

      begin
        run_pending
        yield
      ensure
        begin
          run_pending
        ensure
          @monitor.exit
        end
      end
    end

    # Runs the block inside the monitor and returns its value, or, in a signal trap, runs it on a
    # thread that the trap starts, as #outside_trap does.
    def synchronize(&block)
      result = exclusively(&block)
      result.equal?(TRAPPED) ? outside_trap { exclusively(&block) } : result
    end

    # Leaves the block, given in a signal trap, on the queue of pending calls, and starts a thread to
    # run them, unless one is running (see #start_runner). Never waits.
    def defer(&block)
      forget_parent_calls
      @pending << block
      start_runner
    end

    # Runs the block, given in a signal trap, on a thread that the trap starts, and returns its value,
    # waiting at most TRAP_WAIT_SECONDS for it (see TrapSafe.hand_off). Does not wait when the trap
    # interrupted the thread inside the monitor, since that thread cannot leave it before the trap
    # returns. Outside the trap, the block enters the monitor and runs the pending calls first.
    def outside_trap(&)
      TrapSafe.hand_off(@monitor.mon_owned? ? 0 : TRAP_WAIT_SECONDS, &)
    end

    # Starts a thread that enters the monitor and runs the pending calls, unless one is running.
    #
    # Called in a signal trap, where a Mutex cannot be locked, after it left a call on the queue. The
    # runner clears @runner, and only then checks for calls still pending, which it runs before it
    # checks again. So a runner that this finds in @runner has not yet made that check, and runs the
    # call left, and a call left after that check finds no runner and starts one. The runner waits
    # until @runner holds it, so that it never clears it before. Two runners may run at once, rarely,
    # which is harmless.
    def start_runner
      return if @runner&.alive?

      started = Thread::Queue.new
      @runner = Thread.new do
        started.pop
        loop do
          @monitor.synchronize { run_pending }
          @runner = nil
          break if @pending.empty?

          @runner = Thread.current
        end
      end
      started << true
    end

    # Run the calls left by signal traps, in the order they were made. Called inside the monitor, on
    # any thread, so it reports what a call raises instead of raising it.
    def run_pending
      return if @pending.empty?

      forget_parent_calls
      while (call = @pending.pop(timeout: 0))
        begin
          call.call
        rescue StandardError, SystemStackError => e
          logger.error("Failed to complete a call made in a signal trap", e)
        end
      end
    end

    # In a forked child, forgets the calls left pending in the parent, which the parent runs, and the
    # parent's runner, which the child does not have.
    def forget_parent_calls
      return if @pid == Process.pid

      @pid    = Process.pid
      @runner = nil
      @pending.clear
    end

    def write(log)
      @processed_count += 1
      @appenders.log(log)
    end

    # Returns [Integer] the number of calls left pending by signal traps in this process. In a forked
    # child, those of the parent are not counted, before the child forgets them (see
    # #forget_parent_calls). Changes nothing, so that it can run in a trap without the monitor.
    def pending_count
      @pid == Process.pid ? @pending.size : 0
    end

    def statistics
      {
        queue_size:     pending_count,
        capped:         false,
        max_queue_size: nil,
        thread_active:  @runner&.alive? || false,
        processed:      @processed_count,
        dropped:        0,
        appenders:      @appenders.stats
      }
    end
  end
end
