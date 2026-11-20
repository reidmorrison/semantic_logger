# Loaded now rather than autoloaded, since a metric can be recorded in a signal trap, where Ruby does
# not allow a require.
require "semantic_logger/metric/exponential_histogram"
require "semantic_logger/metric/snapshot"
require "semantic_logger/metric/aggregator"

module SemanticLogger
  module Metric
    # Internal: collects the metrics of the process for the metric appenders, one per process (see
    # Metric.collector).
    #
    # It knows its Aggregator, its thread, and whether it is collecting. It collects only while a
    # metric appender is present, one whose #metrics_interval is not nil (see Metric::Snapshots):
    # otherwise #record returns at once, so that a metric call costs nothing without one.
    #
    # Its thread ticks at the shortest metrics interval of the appenders, which it asks the processor
    # for at each tick, and hands the snapshot of each interval to the processor (see #deliver), which
    # gives it to the metric appenders. When the processor has none left, it delivers what it holds,
    # stops collecting, and its thread ends. It always asks the current processor, SemanticLogger::Logger.processor,
    # so that it keeps working when SemanticLogger.sync! replaces it.
    #
    # Only the main Ractor collects: the processor of any other one drops its metric calls.
    class Collector
      # Seconds the thread waits before it asks again for the interval when asking failed.
      RETRY_SECONDS = 1

      def initialize(aggregator: Aggregator.new)
        @aggregator = aggregator
        @collecting = false
        @thread     = nil
        @lock       = Mutex.new
        @wakeup     = Thread::Queue.new
        @pid        = ::Process.pid
        @kept_pid   = nil
      end

      # Returns [true|false] whether it collects the metrics recorded, while a metric appender is present.
      def collecting? = @collecting

      # Returns [Thread|nil] the thread that collects at each interval, while it runs.
      def thread = @thread&.alive? ? @thread : nil

      # Records the value (see Aggregator#record) while collecting. Otherwise returns false at once.
      # Never locks a Mutex in a signal trap, and never raises.
      def record(kind, name, value, unit: nil, dimensions: nil, internal: false)
        return false unless @collecting

        @aggregator.record(kind, name, value, unit: unit, dimensions: dimensions, internal: internal)
      end

      # Starts collecting, and the thread that collects at each interval unless it runs, since a metric
      # appender was added. Wakes the thread up, so that it starts the next interval on the shortest
      # interval now, rather than the one it was waiting for.
      #
      # Recording starts with a new interval, without what was recorded before collecting stopped.
      def start
        exclusively do
          restart_interval unless @collecting
          @collecting = true
          spawn unless @thread&.alive?
        end
        wake
        true
      end

      # While collecting, asks the processor for the shortest metrics interval now, such as once a metric
      # appender was removed: when there is none, it delivers what it holds and stops collecting at once,
      # and its thread ends. Wakes the thread up either way, so that it ticks at the interval now.
      def check
        return unless @collecting

        interval_or_stop
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

        snapshot = collect(now)
        return false unless snapshot

        Logger.processor.log_metrics(snapshot)
        true
      end

      # Runs the block, which removes the appender, and returns its value. When the appender is a metric
      # appender, it is first given the metrics recorded so far, and the processor flushed (see
      # Processor#flush), so that it writes them before it is removed, as does every other metric
      # appender, a partial interval early (see Snapshots#flush), except where the processor
      # cannot flush, on the thread of an appender added with async: true or in batches (see
      # Processor#current_thread_inside?), which writes only what it already holds as it is closed (see
      # Snapshots#close). Then stops collecting when it was the last one (see #check).
      def removing(appender)
        return yield unless appender.metrics_interval

        begin
          processor = Logger.processor
          processor.flush if !processor.current_thread_inside? && deliver
          yield
        ensure
          check
        end
      end

      # Runs the block, which closes every appender, and returns its value, once the metric appenders are
      # given the metrics recorded so far, which they write as they are closed. Then stops collecting.
      def closing
        deliver
        yield
      ensure
        check
      end

      # Called in a process started by Process.daemon, before SemanticLogger.reopen: unlike a forked
      # child, it keeps the series inherited from the process that started it, which exits without
      # delivering them.
      def daemonized
        @kept_pid = ::Process.pid
        nil
      end

      # Called by SemanticLogger.reopen. In a forked child, discards the series inherited from the
      # parent, which the parent delivers itself, unless the child was started by Process.daemon (see
      # #daemonized), and starts a thread of its own while collecting. In the same process, starts the
      # thread again while collecting, when it has ended.
      #
      # Takes no lock, so that it can be called in a signal trap, such as one that forks: in a child
      # it replaces the Aggregator, rather than reset it, which locks its Mutex, and the lock and queue
      # inherited from the parent, which a thread of the parent may have held.
      def reopen
        forked = @pid != ::Process.pid
        if forked
          @aggregator = new_aggregator unless @kept_pid == ::Process.pid
          @pid        = ::Process.pid
          @lock       = Mutex.new
          @wakeup     = Thread::Queue.new
          @thread     = nil
        end
        spawn if @collecting && !@thread&.alive?
        nil
      end

      private

      # Runs the block holding the lock, or, where it cannot be locked, such as in a signal trap that
      # adds an appender, without it.
      def exclusively(&)
        TrapSafe.try_synchronize(@lock, &) || yield
      end

      # Returns [Snapshot|nil] the snapshot collected up to `now`, or nil in a signal trap. Each collection
      # of the process runs here, by the thread or a flush.
      def collect(now)
        @aggregator.collect(now)
      rescue ThreadError
        nil
      end

      # Discards what was recorded, and starts a new interval now. In a signal trap, where the
      # Aggregator cannot lock its Mutex, replaces it instead.
      def restart_interval
        @aggregator.reset
      rescue ThreadError
        @aggregator = new_aggregator
      end

      def new_aggregator = Aggregator.new(series_limit: @aggregator.series_limit)

      # Starts the thread, as @thread. It waits until it has been assigned before it runs, so that it
      # never clears @thread (see #interval_or_stop) before then.
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

      # The thread: delivers a snapshot at each tick of the shortest metrics interval, until there is none,
      # or another thread has replaced it.
      def run
        thread    = Thread.current
        last_tick = monotonic
        while (interval = interval_or_stop(thread))
          remaining = last_tick + interval - monotonic
          next @wakeup.pop(timeout: remaining) if remaining.positive?

          last_tick = monotonic
          safely { deliver }
        end
      end

      # Returns [Numeric|nil] the shortest metrics interval of the appenders. Nil once there is none, after
      # delivering what it holds, and no longer collecting. Given the thread, also nil once it is no longer
      # the collector's thread, such as one that a #check stopped, while #start started another.
      #
      # Asks again holding the lock before it stops, since #start, holding it, follows the add of a metric
      # appender.
      def interval_or_stop(thread = nil)
        interval = safely(RETRY_SECONDS) { Logger.processor.metrics_interval }
        safely { deliver } unless interval
        result = nil
        exclusively do
          next if thread && !@thread.equal?(thread)

          result = interval || safely { Logger.processor.metrics_interval }
          next if result

          @collecting = false
          @thread     = nil
        end
        result
      end

      # Runs the block, reporting what it raises to the internal logger rather than end the thread,
      # and then returns the fallback.
      def safely(fallback = nil)
        yield
      rescue StandardError => e
        Logger.processor.logger.error("Failed to collect metrics", e)
        fallback
      end

      def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    @collector = Collector.new

    # Returns [Collector] the collector of the metrics of this process. Main Ractor only.
    def self.collector = @collector
  end
end
