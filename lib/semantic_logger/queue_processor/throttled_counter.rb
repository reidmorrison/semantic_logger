module SemanticLogger
  class QueueProcessor
    # Internal: counts occurrences of a problem, such as a dropped log message, and has it
    # reported at most once per interval instead of once per occurrence.
    #
    # It knows the total number of occurrences, how many there have been since the previous
    # report, and when that report was made. What to report, and where, is up to the caller.
    #
    # Thread-safe: occurrences may be recorded from any thread.
    class ThrottledCounter
      # Returns [Integer] the total number of occurrences recorded.
      attr_reader :total

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
      end

      # Record one or more occurrences.
      #
      # When the previous report was at least `interval` seconds ago, yields the number of
      # occurrences since then (including these) and the seconds elapsed since that report (nil
      # when there has been no report yet), then starts counting afresh for the next report.
      def record(count = 1, interval:)
        @mutex.synchronize do
          @total      += count
          @unreported += count
          now          = Time.now
          elapsed      = @reported_at && (now - @reported_at)
          return if elapsed && elapsed < interval

          yield(@unreported, elapsed)
          @unreported  = 0
          @reported_at = now
        end
      end
    end
  end
end
