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
    # occurrences recorded there wait on a Queue, which it does allow, until a thread started for
    # them, or the next read or record where the Mutex can be locked, adds them in.
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
      # out those recorded in a trap that have not been added in yet.
      def total
        TrapSafe.try_synchronize(@mutex) { add(0) }
        @total
      end

      # Record one or more occurrences.
      #
      # When the previous report was at least `interval` seconds ago, yields the number of
      # occurrences since then (including these) and the seconds elapsed since that report (nil
      # when there has been no report yet), then starts counting afresh for the next report.
      #
      # In a signal trap the occurrences are only counted, and are added in and reported, when a
      # report is due, by a thread started for them, just after the trap (see #wait).
      def record(count = 1, interval:, &report_block)
        report  = nil
        counted = TrapSafe.try_synchronize(@mutex) do
          add(count)
          now     = Time.now
          elapsed = @reported_at && (now - @reported_at)
          unless elapsed && elapsed < interval
            report       = [@unreported, elapsed]
            @unreported  = 0
            @reported_at = now
          end
        end
        return wait(count, interval, &report_block) unless counted

        # Reported without holding the lock, so that the report can record occurrences too.
        yield(*report) if report
      end

      private

      # Leaves occurrences recorded where the lock cannot be taken, such as in a signal trap, on the
      # waiting Queue. The first to wait starts a thread, which can take the lock, to record none:
      # that adds in every occurrence waiting by then, and reports them when a report is due. Any
      # left waiting, such as those that come while it is not due, are added in by the next #record
      # or #total that can lock.
      def wait(count, interval, &report_block)
        @waiting << count
        Thread.new { record(0, interval: interval, &report_block) } if @waiting.size == 1
        nil
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
