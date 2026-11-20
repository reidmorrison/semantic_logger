module SemanticLogger
  module Metric
    # Makes an appender a metric appender: one that is given the snapshot of the metrics of each
    # interval (see Metric::Collector), and takes no log entries.
    #
    # Include it in an appender, derived from SemanticLogger::Subscriber or one of its subclasses, such
    # as SemanticLogger::Appender::Http, and implement #write_metrics(snapshot), which writes a
    # Metric::Snapshot to the destination. An appender that defines its own #initialize passes the
    # `interval:` and `internal_metrics:` options on to `super`, and one that defines its own #flush or
    # #close calls `super` from it.
    #
    #   class MyMetrics < SemanticLogger::Subscriber
    #     include SemanticLogger::Metric::Snapshots
    #
    #     def write_metrics(snapshot)
    #       snapshot.each { |point| ... }
    #     end
    #   end
    #
    #   SemanticLogger.add_appender(metric: MyMetrics.new(interval: 10))
    #
    # It knows its interval, whether it writes Semantic Logger's own metrics, and the snapshot that it
    # holds until its interval has passed. Its methods are called by one thread at a time, as every
    # appender's are.
    module Snapshots
      # Seconds between the snapshots that a metric appender writes, by default.
      DEFAULT_INTERVAL = 60

      # Parameters:
      #   interval: [Numeric]
      #     Seconds between the snapshots it writes. The snapshots of the metric appenders with a
      #     shorter interval are merged until it has passed.
      #     Default: 60
      #
      #   internal_metrics: [true|false]
      #     Whether to write Semantic Logger's own metrics too.
      #     Default: false
      #
      # The other options are those of the appender it is included in.
      def initialize(interval: nil, internal_metrics: false, **args, &)
        interval ||= DEFAULT_INTERVAL
        unless interval.is_a?(Numeric) && interval.real? && interval.positive? && interval.finite?
          raise(ArgumentError, "interval: must be a positive number of seconds, not: #{interval.inspect}")
        end

        @metrics_interval = interval
        @internal_metrics = internal_metrics ? true : false
        @held_snapshot    = nil
        super(**args, &)
      end

      # Returns [Numeric] the seconds between the snapshots it writes. Only a metric appender has one,
      # so it is given the snapshots (see Appenders#log_metrics).
      def metrics_interval = @metrics_interval

      # Returns [true|false] whether it writes Semantic Logger's own metrics too.
      def internal_metrics? = @internal_metrics

      # A metric appender takes no log entries.
      def should_log?(_log) = false

      # Holds the snapshot, merged with the one it holds, without Semantic Logger's own metrics unless
      # it writes them, then writes what it holds once its interval has passed (see #interval_ended?).
      #
      # Two snapshots may arrive out of order (see Collector#deliver), so the earlier one is merged
      # with the later one.
      def log_metrics(snapshot)
        snapshot       = snapshot.without_internal unless @internal_metrics
        held           = @held_snapshot
        @held_snapshot =
          if held.nil?
            snapshot
          elsif snapshot.start_time < held.start_time
            snapshot.merge(held)
          else
            held.merge(snapshot)
          end
        write_held if interval_ended?(snapshot)
        true
      end

      # Writes the snapshot it holds, then flushes the appender.
      def flush
        write_held
        super
      end

      # Writes the snapshot it holds, then closes the appender.
      def close
        write_held
        super
      end

      # Writes the snapshot to the destination. Implemented by the appender.
      def write_metrics(_snapshot)
        raise NotImplementedError, "#{self.class.name} must implement #write_metrics(snapshot)"
      end

      private

      # Whether its interval has passed since the start of the snapshot that it holds, or ends nearer
      # now than when the next snapshot, assumed as long as the latest, arrives.
      def interval_ended?(latest)
        held = @held_snapshot
        (held.end_time - held.start_time) + ((latest.end_time - latest.start_time) / 2.0) >= @metrics_interval
      end

      # Writes the snapshot it holds, unless it holds none, or one without points, and no longer holds it,
      # even when writing it fails.
      def write_held
        held           = @held_snapshot
        @held_snapshot = nil
        write_metrics(held) if held && !held.empty?
      end
    end
  end
end
