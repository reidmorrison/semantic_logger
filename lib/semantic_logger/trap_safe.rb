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
    # which the trap waits for, at most ADD_WAIT_SECONDS, then returns the value that the map holds.
    # The new thread cannot add it while the thread that the trap interrupted is adding to the map,
    # holding its Mutex: the trap then returns the block's value, and the new thread adds it just after
    # the trap, unless another thread has added one for the key by then.
    def self.compute_if_absent(map, key, &)
      value = map[key]
      return value unless value.nil?
      return map.compute_if_absent(key, &) unless in_trap?

      value  = yield
      adding = Thread.new { map.compute_if_absent(key) { value } }
      adding.join(ADD_WAIT_SECONDS) ? adding.value : value
    end
  end
end
