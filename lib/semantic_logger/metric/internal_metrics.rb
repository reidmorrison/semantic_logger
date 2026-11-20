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
    #                     among them at that collection, as "<name>#2", "<name>#3", and so on.
    #       "error.type": "dropped" for the entries dropped because the queue was full, "failed" for
    #                     those discarded because they could not be written. Absent for the entries
    #                     written.
    #
    # Appenders without a queue of their own are written to by the main queue, so they have no count
    # of their own.
    #
    # It knows the cumulative counts that it read at the previous collection, by the object that owns
    # each queue (see ProcessorMethods#each_queue_log_counts), and records the difference, so that a
    # queue is never compared with another one, such as when SemanticLogger.sync! replaces the
    # processor, or an appender removed leaves its name to another one. A queue first read since the
    # previous collection is counted from zero. A queue read then but gone now, however it went (an
    # appender removed, by the worker thread or not, or a processor replaced by SemanticLogger.sync!),
    # is asked for its counts once more, which records what it counted until it went, and the entries
    # it wrote as it was closed, under the name it was reported by then; then it is forgotten. It reads
    # the counts only while the processor has a metric appender that writes them, so that logging pays
    # nothing for them, nor does a collection for the other metric appenders.
    class InternalMetrics
      # The name of the counter.
      NAME = "semantic_logger.log.processed".freeze

      # The unit of the counter, as OpenTelemetry names it.
      UNIT = "{log_record}".freeze

      # The "appender" dimension of the main queue.
      MAIN = "main".freeze

      # The "error.type" dimension of each count, nil for the entries written.
      ERROR_TYPES = {processed: nil, dropped: "dropped", failed: "failed"}.freeze

      # The counts of a queue read at a collection, with the name they were reported by.
      Read = Struct.new(:name, :counts)
      private_constant :Read

      # Parameters:
      #   previous: [Hash|nil]
      #     The counts read at the previous collection, by the object that owns each queue (compared
      #     by identity), or nil when none were read.
      def initialize(previous: nil)
        @previous = previous
        @lock     = Mutex.new
      end

      # Reads the counts now, when the processor has a metric appender that writes them and none were
      # read since, so that the next collection records only what was counted from now on, rather than
      # since the process started. Called once a metric appender was added.
      #
      # Given `restart: true`, when collecting starts again after it stopped, first forgets the counts
      # read before, which no collection compared since, such as when a check could not lock in a signal
      # trap (see #check). Forgets them without the lock, which no collection holds while collecting is
      # stopped, so that where the lock cannot be locked, the next collection reads a new baseline.
      def baseline(processor = Logger.processor, restart: false)
        @previous = nil if restart
        return false unless processor.internal_metrics?

        TrapSafe.try_synchronize(@lock) { @previous ||= counts(processor) }
      end

      # Records in the aggregator, as internal counters, what was counted since the previous collection,
      # when the processor has a metric appender that writes them: by each queue read now, and by each
      # queue read at the previous collection but gone since, which it asks for its counts once more and
      # then forgets. Otherwise forgets the counts that it read, and reads none.
      #
      # Returns false without recording where its lock cannot be locked, in a signal trap: the next
      # collection records what was counted meanwhile.
      def record(aggregator, processor = Logger.processor)
        TrapSafe.try_synchronize(@lock) do
          next @previous = nil unless processor.internal_metrics?

          current   = counts(processor)
          previous  = @previous
          @previous = current
          next unless previous

          current.each_pair { |owner, read| record_increase(aggregator, read, previous[owner]&.counts) }
          previous.each_pair do |owner, read|
            record_gone(aggregator, owner, read) unless current.key?(owner)
          end
        end
      end

      # Forgets the counts that it read, once the processor has no metric appender that writes them,
      # such as once the last one was removed, so that one added later counts from then on, rather than
      # from the counts read before. Returns at once while it holds no counts.
      def check(processor = Logger.processor)
        return false unless @previous
        return false if processor.internal_metrics?

        TrapSafe.try_synchronize(@lock) { @previous = nil unless processor.internal_metrics? }
      end

      # Returns [InternalMetrics] the one for a child process, with a lock of its own, since a thread
      # of the parent may have held this one. A process started by Process.daemon, given `keep: true`,
      # keeps the counts read at the previous collection, since it reports what was counted since then,
      # which the process that started it does not. A forked child reads them now, since the parent
      # reports what it counted before the fork. Takes no lock, so that it can be called in a signal trap.
      def for_child(keep:, processor: Logger.processor)
        return self.class.new(previous: @previous&.dup) if keep

        self.class.new(previous: processor.internal_metrics? ? counts(processor) : nil)
      end

      private

      # Returns [Hash] the counts of each queue of the processor, by the object that owns it, with the
      # name they are reported by.
      def counts(processor)
        counts = {}.compare_by_identity
        used   = Hash.new(0)
        processor.each_queue_log_counts do |owner, name, owner_counts|
          name          = name.nil? ? MAIN : name.to_s
          position      = used[name] += 1
          name          = "#{name}##{position}" if position > 1
          counts[owner] = Read.new(name, owner_counts)
        end
        counts
      end

      # Records what the queue of `owner`, gone since the previous collection, counted since then, under
      # the name it was reported by then.
      def record_gone(aggregator, owner, read)
        counts = owner.queue_log_counts
        record_increase(aggregator, Read.new(read.name, counts), read.counts) if counts
      end

      # Records each count of `read` that went up since `before`, or since zero without them.
      def record_increase(aggregator, read, before)
        ERROR_TYPES.each_pair do |statistic, error_type|
          total = read.counts[statistic]
          next unless total.is_a?(Integer)

          amount = total - (before ? before.fetch(statistic, 0) : 0)
          next unless amount.positive?

          dimensions = {"appender" => read.name}
          dimensions["error.type"] = error_type if error_type
          aggregator.record(:counter, NAME, amount, unit: UNIT, dimensions: dimensions, internal: true)
        end
      end
    end
  end
end
