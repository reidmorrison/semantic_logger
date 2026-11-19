module SemanticLogger
  # Internal: locks a Mutex only where Ruby allows it, for code that can run in a signal trap, such as
  # a trap that logs, or one that reopens the log files after a rotation.
  #
  # Ruby raises ThreadError for Mutex#lock in a trap. Queue and Thread methods are allowed there, so
  # a caller that cannot lock leaves its work on a Queue, or to a new Thread, instead.
  module TrapSafe
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
  end
end
