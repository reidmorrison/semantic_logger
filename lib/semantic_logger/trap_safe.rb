module SemanticLogger
  # Internal: locks a Mutex only where Ruby allows it, for code that can run in a signal trap, such as
  # a trap that logs, or one that reopens the log files after a rotation.
  #
  # Ruby raises ThreadError for Mutex#lock in a trap. Queue and Thread methods are allowed there, so
  # a caller that cannot lock leaves its work on a Queue, or to a new Thread, instead.
  module TrapSafe
    # Seconds that .compute_if_absent waits in a signal trap for a new thread to add the value.
    ADD_WAIT_SECONDS = 0.1

    # Runs the block holding the mutex, and returns true. Returns false, without running the block,
    # where the mutex cannot be locked: in a signal trap, or on a thread that already holds it, such
    # as one that a signal trap interrupted while it did. A ThreadError raised by the block itself is
    # raised again.
    def self.try_synchronize(mutex)
      return false if mutex.owned?

      held = false
      mutex.synchronize do
        held = true
        yield
      end
      true
    rescue ThreadError
      raise if held

      false
    end

    # Returns [true|false] whether the calling code runs in a signal trap, for code that writes to a
    # structure that locks a Mutex of its own, such as a Concurrent::Map on CRuby, which it then must
    # not write to. A new Mutex is never held, so only a trap keeps it from being locked.
    def self.in_trap?
      ::Mutex.new.synchronize { false }
    rescue ThreadError
      true
    end

    # Returns the value that the Concurrent::Map holds for the key, adding the one that the block
    # returns when it holds none, as Concurrent::Map#compute_if_absent does.
    #
    # Adding to it locks a Mutex on CRuby, so in a signal trap a new thread adds the block's value,
    # which the trap waits for, at most ADD_WAIT_SECONDS (see .hand_off), then returns the value that
    # the map holds. The new thread cannot add it while the thread that the trap interrupted is adding
    # to the map, holding its Mutex: the trap then returns the block's value, and the new thread adds
    # it just after the trap, unless another thread has added one for the key by then.
    def self.compute_if_absent(map, key, &)
      value = map[key]
      return value unless value.nil?
      return map.compute_if_absent(key, &) unless in_trap?

      value = yield
      hand_off(ADD_WAIT_SECONDS) { map.compute_if_absent(key) { value } } || value
    end

    # Runs the block on a new thread, for code in a signal trap whose work locks a Mutex, and waits for
    # it at most the given seconds, since that thread may need a lock that the thread the trap
    # interrupted holds, which it cannot release before the trap returns.
    #
    # Returns the block's value, or raises what it raised, when it finished in time. Otherwise returns
    # nil, and the block finishes after that, when Ruby reports what it raises, if anything, as for any
    # thread (see Thread#report_on_exception). Either way an exception is raised or reported, never
    # both: the caller and the thread each take the one token of a queue, without waiting, as the
    # caller stops waiting and as the block finishes, and whichever takes it first decides.
    def self.hand_off(seconds)
      started = Thread::Queue.new
      token   = Thread::Queue.new
      done    = Thread::Queue.new
      token << true
      decided = false
      thread  = nil
      begin
        thread = Thread.new do
          started.pop
          yield
        ensure
          # Ruby reports what the block raised only when the caller took the token, as it stopped waiting.
          Thread.current.report_on_exception = token.pop(timeout: 0).nil?
          done << true
        end
        started << true
        # Waits on a queue rather than Thread#join, which would raise what the block raised before the
        # outcome is decided. The thread took the token when it has finished, or is about to, so the
        # caller gets the outcome. Otherwise the caller takes it as it stops waiting, so that Ruby
        # reports what the block raises.
        caller_gets = done.pop(timeout: seconds) || !token.pop(timeout: 0)
        decided     = true
        caller_gets ? thread.value : nil
      ensure
        report_outcome(thread, token, started) if thread && !decided
      end
    end

    # Called when the caller of .hand_off is interrupted, such as by another signal, before it decided who
    # gets the block's outcome: it lets the thread start, then takes the token if the thread has not, so
    # that Ruby reports what the block raises, and otherwise, once the thread has finished, reports it
    # here, as Ruby would have, to standard error, so that it is never lost. An interrupt while it waits
    # for the thread is raised, not reported as the block's.
    def self.report_outcome(thread, token, started)
      started << true
      return if token.pop(timeout: 0)

      begin
        thread.join
      rescue Exception => e
        raise if thread.alive?

        $stderr.write("#{thread.inspect} terminated with exception (report_on_exception is true):\n#{e.full_message}")
      end
    end
    private_class_method :report_outcome
  end
end
