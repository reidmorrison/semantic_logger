module SemanticLogger
  module Metric
    # Internal: Semantic Logger's own metrics, which it records at each collection (see Collector) for
    # the metric appenders that write them, those added with `internal_metrics: true` (see Snapshots).
    #
    # One counter, named as OpenTelemetry names the counter of its own log processors:
    #
    #   semantic_logger.log.processed, unit "{log_record}"
    #     The log entries that a queue has finished with since the previous collection, with the
    #     dimensions:
    #       "appender":   "main" for the main queue of the processor, otherwise the name of an appender
    #                     with a queue of its own, added with async: true or in batches. Each further
    #                     one with a name already used, "main" included, is told apart by its position
    #                     among them, as "<name>#2", "<name>#3", and so on.
    #       "error.type": "dropped" for the entries dropped because the queue was full, "failed" for
    #                     those discarded because they could not be written. Absent for the entries
    #                     written.
    #
    # Appenders without a queue of their own are written to by the main queue, so they have no count
    # of their own.
    #
    # It knows the cumulative totals that it read at the previous collection, and records the
    # difference. It reads them from the statistics of the processor (see SemanticLogger.stats), only
    # while the processor has a metric appender that writes them, so that logging pays nothing for
    # them, nor does a collection for the other metric appenders.
    #
    # A total lower than at the previous collection was reset, such as by SemanticLogger.sync!, which
    # replaces the processor: the new total is then recorded, never a negative difference.
    class InternalMetrics
      # The name of the counter.
      NAME = "semantic_logger.log.processed".freeze

      # The unit of the counter, as OpenTelemetry names it.
      UNIT = "{log_record}".freeze

      # The "appender" dimension of the main queue.
      MAIN = "main".freeze

      # The "error.type" dimension of each statistic counted, nil for the entries written.
      ERROR_TYPES = {processed: nil, dropped: "dropped", failed: "failed"}.freeze

      # Parameters:
      #   previous: [Hash|nil]
      #     The totals read at the previous collection, by dimensions, or nil when none were read.
      def initialize(previous: nil)
        @previous = previous
        @lock     = Mutex.new
      end

      # Reads the totals now, when the processor has a metric appender that writes them and none were
      # read since, so that the next collection records only what was counted from now on, rather than
      # since the process started. Called once a metric appender was added.
      def baseline(processor = Logger.processor)
        return false unless wanted?(processor)

        TrapSafe.try_synchronize(@lock) { @previous ||= totals(processor) }
      end

      # Records in the aggregator, as internal counters, what was counted since the previous collection,
      # when the processor has a metric appender that writes them. Otherwise forgets the totals that it
      # read, and reads none.
      #
      # Returns false without recording where its lock cannot be locked, in a signal trap: the next
      # collection records what was counted meanwhile.
      def record(aggregator, processor = Logger.processor)
        TrapSafe.try_synchronize(@lock) do
          next @previous = nil unless wanted?(processor)

          current   = totals(processor)
          previous  = @previous
          @previous = current
          next unless previous

          current.each_pair do |key, total|
            amount = total - previous.fetch(key, 0)
            amount = total if amount.negative?
            next if amount.zero?

            aggregator.record(:counter, NAME, amount, unit: UNIT, dimensions: key.last, internal: true)
          end
        end
      end

      # Returns [InternalMetrics] the one for a child process, with a lock of its own, since a thread
      # of the parent may have held this one. A process started by Process.daemon, given `keep: true`,
      # keeps the totals read at the previous collection, since it reports what was counted since then,
      # which the process that started it does not. A forked child reads them now, since the parent
      # reports what it counted before the fork. Takes no lock, so that it can be called in a signal trap.
      def for_child(keep:, processor: Logger.processor)
        return self.class.new(previous: @previous) if keep

        self.class.new(previous: wanted?(processor) ? totals(processor) : nil)
      end

      private

      # Whether the processor has a metric appender that writes Semantic Logger's own metrics.
      def wanted?(processor)
        processor.respond_to?(:internal_metrics?) && processor.internal_metrics?
      end

      # Returns [Hash] the cumulative totals of the processor's statistics, by [owner, dimensions]: the
      # owner of the totals of the main queue is the processor, since the main queue of a new processor
      # starts its counts afresh; nil for those of an appender, which keeps its queue when the processor
      # is replaced.
      def totals(processor)
        stats  = processor.stats
        totals = {}
        add_totals(totals, [processor, MAIN], stats)
        names = Hash.new(0)
        names[MAIN] += 1
        Array(stats[:appenders]).each do |appender|
          next unless appender[:async]

          name   = appender[:name].to_s
          count  = names[name] += 1
          name   = "#{name}##{count}" if count > 1
          add_totals(totals, [nil, name], appender)
        end
        totals
      end

      def add_totals(totals, (owner, name), stats)
        ERROR_TYPES.each_pair do |statistic, error_type|
          total = stats[statistic]
          next unless total.is_a?(Integer)

          dimensions = {"appender" => name}
          dimensions["error.type"] = error_type if error_type
          totals[[owner, dimensions.freeze]] = total
        end
      end
    end
  end
end
