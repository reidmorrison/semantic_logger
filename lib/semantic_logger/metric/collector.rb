# Loaded now rather than autoloaded, since a metric can be recorded in a signal trap, where Ruby does
# not allow a require.
require "semantic_logger/metric/exponential_histogram"
require "semantic_logger/metric/snapshot"
require "semantic_logger/metric/aggregator"
require "semantic_logger/metric/validator"
require "semantic_logger/metric/internal_metrics"

module SemanticLogger
  module Metric
    # Internal: collects the metrics of the process for the metric appenders, one per process (see
    # Metric.collector).
    #
    # It knows its Aggregator, its thread, whether it is collecting, the process it collects for, and
    # the metric names whose dropped records it has reported. It collects only while a metric appender
    # is present, one whose #metrics_interval is not nil (see Metric::Snapshots): otherwise #record
    # returns at once, so that a metric call costs nothing without one.
    #
    # Before it records a metric, it asks its Validator whether to drop it, such as a negative counter
    # amount, which warns once on the internal logger.
    #
    # At each collection it first asks its InternalMetrics to record Semantic Logger's own metrics,
    # which they do only while a metric appender writes them.
    #
    # Its thread ticks at the shortest metrics interval of the appenders, which it asks the processor
    # for at each tick (see Metric::ProcessorMethods#shortest_metrics_interval), and hands the snapshot
    # of each interval to the processor (see #deliver), which gives it to the metric appenders. It
    # always asks the current processor, SemanticLogger::Logger.processor, so that it keeps working when
    # SemanticLogger.sync! replaces it. Once the processor answers none, at a tick or when told that a
    # metric appender was removed (see #check), it stops collecting, however the last one was removed.
    # A stand-in for the processor in a test answers both questions too (see
    # Test::CaptureLogEvents#shortest_metrics_interval); when asking one fails, that is reported, and
    # the thread asks again IDLE_SECONDS later, without stopping.
    #
    # It reports the records that the Aggregator dropped in each interval (see #report_dropped).
    #
    # It asks each snapshot to redact the dimensions whose keys are sensitive, when there are
    # sensitive keys, before any metric appender is given it (see #redact).
    #
    # Only the main Ractor collects: the processor of any other one drops its metric calls.
    class Collector
      # Seconds the thread waits before it asks the processor again for the interval, when asking failed.
      IDLE_SECONDS = 1

      # Number of metric names whose records dropped for a kind or unit conflict it reports, once each.
      # Beyond it, it reports no other name, so that a process that keeps making new names is not
      # reported for each.
      REPORTED_CONFLICTS_LIMIT = 1000

      def initialize(aggregator: Aggregator.new, validator: Validator.new, internal_metrics: InternalMetrics.new)
        @aggregator                  = aggregator
        @validator                   = validator
        @internal_metrics            = internal_metrics
        @collecting                  = false
        @thread                      = nil
        @lock                        = Mutex.new
        @wakeup                      = Thread::Queue.new
        @pid                         = ::Process.pid
        @conflicts_reported          = Concurrent::Map.new
        @internal_conflicts_reported = Concurrent::Map.new
      end

      # Returns [true|false] whether it collects the metrics recorded, while a metric appender is present.
      def collecting? = @collecting

      # Returns [Thread|nil] the thread that collects at each interval, while it runs.
      def thread = @thread&.alive? ? @thread : nil

      # Records the value (see Aggregator#record) while collecting, unless the Validator drops it (see
      # Validator#accept). Otherwise returns false, at once when not collecting. Never locks a Mutex in a
      # signal trap, and never raises: when the Aggregator raises, such as for a dimension value without
      # #hash, returns false after reporting it once for the metric name (see #report_failure). When it
      # fails itself, a defect, it reports that once for every metric name (see
      # Validator#report_collector_failure).
      #
      # In a forked child that was not reopened, such as one forked while SemanticLogger.reopen_on_fork
      # is false, first discards the series inherited from the parent (see #renew_after_fork).
      def record(kind, name, value, unit: nil, dimensions: nil, internal: false)
        return false unless @collecting
        return false unless (name = @validator.accept(kind, name, value, dimensions))

        renew_after_fork unless @pid == ::Process.pid
        begin
          @aggregator.record(kind, name, value, unit: unit, dimensions: dimensions, internal: internal)
        rescue StandardError => e
          report_failure(kind, name, e)
        end
      rescue StandardError => e
        @validator.report_collector_failure(kind, name, e)
      end

      # Reports, once for each metric name, that recording the metric raised `exception` (see
      # Validator#report_failure), and returns false. Also asked by SemanticLogger::Base, when the
      # processor raises as it is asked to record a metric. Never raises.
      def report_failure(kind, name, exception)
        @validator.report_failure(kind, name, exception)
      end

      # Starts collecting, and the thread that collects at each interval unless it runs, since a metric
      # appender was added. Wakes the thread up, so that it starts the next interval on the shortest
      # interval now, rather than the one it was waiting for.
      #
      # Recording starts with a new interval, without what was recorded before collecting stopped. Semantic
      # Logger's own metrics are counted from now on, when the appender writes them and none did before,
      # forgetting any counts read before collecting stopped (see InternalMetrics#baseline).
      #
      # While already collecting, it does not start a new interval: the appender added is given the
      # snapshot of the current interval at its end, which holds what was recorded since it started,
      # before the appender was added.
      def start
        restarted = false
        exclusively do
          restarted = !@collecting
          restart_interval if restarted
          @collecting = true
          spawn unless @thread&.alive?
        end
        safely { @internal_metrics.baseline(restart: restarted) }
        wake
        true
      end

      # While collecting, asks the processor for the shortest metrics interval now, once a metric
      # appender was removed, or the appenders closed: when there is none, it stops collecting at once,
      # and its thread ends (see #interval_or_stop). Wakes the thread up either way, so that it ticks at
      # the interval now. When asking fails, it carries on collecting.
      #
      # First, once no metric appender writes Semantic Logger's own metrics, its InternalMetrics forget
      # the counts they read (see InternalMetrics#check).
      def check
        safely { @internal_metrics.check }
        return unless @collecting

        safely { interval_or_stop }
        wake
        nil
      end

      # Collects the snapshot of the metrics recorded since the last one, up to `now`, and hands it to the
      # current processor, which gives it to the metric appenders (see Processor#log_metrics). Returns
      # false without collecting when not collecting.
      #
      # In a signal trap, where the Aggregator cannot lock its Mutex, returns false without collecting:
      # the next tick, or flush, outside the trap, delivers what it holds.
      #
      # Called by the thread at each interval, and by SemanticLogger.flush, so that the flush at exit
      # delivers the last partial interval. The snapshots of two calls at once may reach the appenders
      # in either order, which they allow for (see Snapshots#log_metrics).
      def deliver(now = Time.now)
        return false unless @collecting

        renew_after_fork unless @pid == ::Process.pid
        snapshot = collect(now)
        return false unless snapshot

        report_dropped(snapshot) if snapshot.dropped?
        Logger.processor.log_metrics(snapshot)
        true
      end

      # Runs the block, which removes the appender, and returns its value. When the appender is a metric
      # appender, it is first given the metrics recorded so far, which it writes as it is closed (see
      # Snapshots#close), and the processor flushed (see Processor#flush), so that every other metric
      # appender writes them too, a partial interval early (see Snapshots#flush). Not where the
      # processor cannot flush (see Processor#current_thread_inside?), such as on the thread of an
      # appender added with async: true or in batches, which hands the metrics over ahead of the
      # removal, or inside a call to the SyncProcessor, which gives them at once: the others write them
      # at their next interval. On the worker thread of the processor itself, the processor gives them
      # at once (see Processor#log_metrics). Then stops collecting when it was the last one (see
      # #check).
      def removing(appender)
        return yield unless appender.metrics_interval

        begin
          processor = Logger.processor
          processor.flush if deliver && !processor.current_thread_inside?
          yield
        ensure
          check
        end
      end

      # Runs the block, which flushes the processor (see SemanticLogger.flush), and returns its value, once
      # the metric appenders are given the metrics recorded so far, which they write as they are flushed.
      # The processor writes and flushes the log entries that a metric appender writes as it is flushed,
      # such as Metric::Summary, before its flush returns (see Processor#log_aside), such as the flush at
      # exit.
      def flushing
        deliver
        yield
      end

      # Runs the block, which closes every appender, and returns its value, once the metric appenders are
      # given the metrics recorded so far, and the processor flushed while a metric appender is present,
      # so that they write what they hold as they are flushed, and the log entries that a metric appender
      # writes then, such as Metric::Summary, are written before the appenders are closed, even in a
      # signal trap, where the metrics recorded since the last interval cannot be collected. Then stops
      # collecting.
      def closing
        deliver
        Logger.processor.flush if @collecting
        yield
      ensure
        check
      end

      # Called by SemanticLogger.reopen. In a forked child, discards the series inherited from the
      # parent, which the parent delivers itself, unless the child was started by Process.daemon (see
      # CoreExt::Process.daemon?), and likewise counts Semantic Logger's own metrics from now on (see
      # InternalMetrics#for_child), and starts a thread of its own while collecting. In the same process,
      # starts the thread again while collecting, when it has ended.
      #
      # Takes no lock, so that it can be called in a signal trap, such as one that forks.
      def reopen
        renew_after_fork unless @pid == ::Process.pid
        spawn if @collecting && !@thread&.alive?
        nil
      end

      private

      # Runs the block holding the lock, or, where it cannot be locked, such as in a signal trap that
      # adds an appender, without it.
      def exclusively(&)
        TrapSafe.try_synchronize(@lock, &) || yield
      end

      # In a forked child: replaces the Aggregator, unless the child was started by Process.daemon, and
      # the lock and queue inherited from the parent, which a thread of the parent may have held, and
      # forgets the parent's thread. Replaces the Aggregator rather than reset it, which locks its
      # Mutex, so that it takes no lock. Replaces its InternalMetrics too (see InternalMetrics#for_child),
      # keeping the counts they read in a child started by Process.daemon.
      #
      # The pid is changed last, so that another thread of the child that checks it meanwhile renews
      # too, rather than record into the parent's Aggregator. Two threads of the child that renew at
      # once may each replace the Aggregator, so that a record made into the first new one before the
      # second replaces it is lost: a tiny race, only in the first moments of a child that was not
      # reopened, which is accepted rather than take a lock here, where none can be taken in a trap.
      def renew_after_fork
        kept              = CoreExt::Process.daemon?
        @aggregator       = new_aggregator unless kept
        @internal_metrics = safely(@internal_metrics) { @internal_metrics.for_child(keep: kept) }
        @lock             = Mutex.new
        @wakeup           = Thread::Queue.new
        @thread           = nil
        @pid              = ::Process.pid
      end

      # Returns [Snapshot|nil] the snapshot collected up to `now`, with Semantic Logger's own metrics
      # (see InternalMetrics#record), its dimensions redacted (see #redact), or nil in a signal trap. Each
      # collection of the process runs here, by the thread or a flush.
      def collect(now)
        safely { @internal_metrics.record(@aggregator) }
        redact(@aggregator.collect(now))
      rescue ThreadError
        nil
      end

      # Returns [Snapshot] the snapshot with the value of each dimension whose key is sensitive replaced
      # (see SemanticLogger.sensitive_keys= and Snapshot#redact), so that no metric appender is given one,
      # or the snapshot itself without sensitive keys. Once per collection rather than per record, so that
      # it costs once per series. A structure given as a dimension value, such as a Hash, was redacted as
      # it was recorded, before it became text (see Aggregator.text).
      #
      # A point that cannot be redacted, such as when the sensitive keys raise, is never delivered: it
      # is left out (see Snapshot#redact), the others are delivered, and how many were left out is
      # reported once for the interval, with the first error. Should redacting the snapshot raise
      # itself, a defect, only Semantic Logger's own metrics are delivered (see Snapshot#only_internal),
      # and the records dropped in the interval are still reported. Only the error's class and where it
      # was raised are reported, since its message could hold the value being redacted.
      def redact(snapshot)
        redactor = SemanticLogger.redactor
        return snapshot unless redactor

        failed = 0
        error  = nil
        redacted = snapshot.redact(redactor) do |exception|
          failed += 1
          error ||= exception
        end
        report_redaction_failure(snapshot, failed, error) if error
        redacted
      rescue StandardError => e
        report_redaction_failure(snapshot, snapshot.size, e)
        snapshot.only_internal
      end

      def report_redaction_failure(snapshot, failed, exception)
        where = exception.backtrace&.first
        report(
          :error,
          "Redacting the dimensions of metrics raised #{Utils.exception_name(exception)}" \
          "#{" (#{where})" if where}, so #{failed} of the #{snapshot.size} metric series from " \
          "#{snapshot.start_time} to #{snapshot.end_time} were not delivered"
        )
      rescue StandardError
        nil
      end

      # Discards what was recorded, and starts a new interval now. In a signal trap, where the
      # Aggregator cannot lock its Mutex, replaces it instead.
      def restart_interval
        @aggregator.reset
      rescue ThreadError
        @aggregator = new_aggregator
      end

      def new_aggregator = Aggregator.new(series_limit: @aggregator.series_limit, name_limit: @aggregator.name_limit)

      # Reports to the internal logger the records that the Aggregator dropped in the interval of the
      # snapshot: those beyond its limit of metric names, once per interval, naming the first one, and
      # those of a metric name recorded with another kind or unit than the first, once per name. The
      # latter among Semantic Logger's own metrics are reported apart (see #report_internal_conflicts).
      def report_dropped(snapshot)
        if snapshot.dropped_by_name_limit.positive?
          report(
            :warn,
            "Dropped #{snapshot.dropped_by_name_limit} metric records from #{snapshot.start_time} to " \
            "#{snapshot.end_time}, since that interval already had #{@aggregator.name_limit} metric names, " \
            "starting with #{snapshot.first_name_dropped.inspect}. " \
            "Put variable parts in dimensions: instead of the metric name."
          )
        end
        snapshot.dropped_by_conflict.each do |name, count|
          next if @conflicts_reported.size >= REPORTED_CONFLICTS_LIMIT
          next unless @conflicts_reported.put_if_absent(name, true).nil?

          report(
            :warn,
            "Dropped #{count} records of metric #{name.inspect} from #{snapshot.start_time} to " \
            "#{snapshot.end_time}, with a kind or unit other than the one it was first recorded with in " \
            "that interval. Give each metric name one kind and unit. Reported once per metric name."
          )
        end
        report_internal_conflicts(snapshot)
      end

      # Reports, as an error, once per metric name, the records of Semantic Logger's own metrics dropped
      # for another kind or unit than the first, which only a defect of Semantic Logger records, since
      # each of its own metrics has one kind and unit. Counted apart from the application's metrics,
      # whose names they may share (see Snapshot#dropped_by_internal_conflict).
      def report_internal_conflicts(snapshot)
        snapshot.dropped_by_internal_conflict.each do |name, count|
          next if @internal_conflicts_reported.size >= REPORTED_CONFLICTS_LIMIT
          next unless @internal_conflicts_reported.put_if_absent(name, true).nil?

          report(
            :error,
            "Dropped #{count} records of Semantic Logger's own metric #{name.inspect} from " \
            "#{snapshot.start_time} to #{snapshot.end_time}, with a kind or unit other than the one it was " \
            "first recorded with in that interval. This is a defect of Semantic Logger: please report it. " \
            "Reported once per metric name."
          )
        end
      end

      # Starts the thread, as @thread. It waits until it has been assigned before it runs, so that it
      # never checks @thread (see #run) before then.
      def spawn
        started = Thread::Queue.new
        @thread = Thread.new do
          started.pop
          Thread.current.name = "SL Metrics"
          run
        end
        started << true
      end

      # Wakes the thread up, so that it asks for the interval again. Takes no lock.
      def wake
        @wakeup << :wake
      end

      # The thread: delivers a snapshot at each tick of the shortest metrics interval, until it is no
      # longer the collector's thread, such as once the processor answered no interval (see
      # #interval_or_stop), while #start may have started another. When asking the processor fails, it
      # delivers nothing, and asks again IDLE_SECONDS later.
      def run
        thread    = Thread.current
        last_tick = monotonic
        while @thread.equal?(thread)
          interval = safely { interval_or_stop }
          break unless @thread.equal?(thread)
          next @wakeup.pop(timeout: IDLE_SECONDS) unless interval

          remaining = last_tick + interval - monotonic
          next @wakeup.pop(timeout: remaining) if remaining.positive?

          last_tick = monotonic
          safely { deliver }
        end
      end

      # Returns [Numeric|nil] the shortest metrics interval of the appenders of the current processor.
      # When it has none, stops collecting, so that its thread ends, and returns nil.
      #
      # Asks holding the lock, since #start, holding it, follows the add of a metric appender: either
      # this sees the appender added, or #start, after it, collects again.
      def interval_or_stop
        interval = nil
        exclusively do
          interval = Logger.processor.shortest_metrics_interval
          unless interval
            @collecting = false
            @thread     = nil
          end
        end
        interval
      end

      # Runs the block, reporting what it raises to the internal logger rather than end the thread,
      # and then returns the fallback.
      def safely(fallback = nil)
        yield
      rescue StandardError => e
        report(:error, "Failed to collect metrics", e)
        fallback
      end

      # Reports to the internal logger of the current processor.
      def report(level, message, exception = nil)
        Logger.processor.logger.public_send(level, message, exception)
      end

      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    @collector = Collector.new

    # Returns [Collector] the collector of the metrics of this process. Main Ractor only.
    def self.collector = @collector
  end
end
