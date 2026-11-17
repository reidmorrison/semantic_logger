module SemanticLogger
  class QueueProcessor
    # Internal: counts occurrences of a problem, such as a dropped log message, and has it
    # reported at most once per interval instead of once per occurrence.
    #
    # It knows the total number of occurrences, how many there have been since the previous
    # report, and when that report was made. What to report, and where, is up to the caller.
    #
    # Thread-safe: occurrences may be recorded from any thread, and from a signal trap, such as one
    # that logs while the queue is full. Ruby does not allow a Mutex to be locked in a trap, so the
    # occurrences recorded there wait on a Queue, which it does allow, until the counter is next read
    # or recorded to where the Mutex can be locked.
    class ThrottledCounter
      # Parameters:
      #   reported_at: [Time|nil]
      #     When counting starts, so that the first report is due one interval later.
      #     nil: Report the first occurrence straight away.
      #     Default: Time.now
      def initialize(reported_at: Time.now)
        @reported_at = reported_at
        @total       = 0
        @unreported  = 0
        @mutex       = Mutex.new
        @waiting     = Queue.new
      end

      # Returns [Integer] the total number of occurrences recorded. Read in a signal trap, it leaves
      # out those recorded in a trap since the counter was last read or recorded to outside one.
      def total
        locked { add(0) }
        @total
      end

      # Record one or more occurrences.
      #
      # When the previous report was at least `interval` seconds ago, yields the number of
      # occurrences since then (including these) and the seconds elapsed since that report (nil
      # when there has been no report yet), then starts counting afresh for the next report.
      #
      # In a signal trap the occurrences are only counted, and are reported with those recorded next.
      def record(count = 1, interval:)
        report  = nil
        counted = locked do
          add(count)
          now     = Time.now
          elapsed = @reported_at && (now - @reported_at)
          unless elapsed && elapsed < interval
            report       = [@unreported, elapsed]
            @unreported  = 0
            @reported_at = now
          end
        end
        @waiting << count unless counted
        # Reported without holding the lock, so that the report can record occurrences too.
        yield(*report) if report
      end

      private

      # Runs the block holding the lock, and returns true. Returns false, without running the block,
      # when the lock cannot be taken: in a signal trap, where Ruby raises ThreadError for Mutex#lock,
      # or on a thread that already holds it, such as one a signal trap interrupted while it did.
      def locked
        return false if @mutex.owned?

        held = false
        @mutex.synchronize do
          held = true
          yield
        end
        true
      rescue ThreadError
        raise if held

        false
      end

      # Adds the occurrences, and those waiting on the queue, to the counts. Holding the lock.
      def add(count)
        while (waiting = @waiting.pop(timeout: 0))
          count += waiting
        end
        @total      += count
        @unreported += count
      end
    end
  end
end
