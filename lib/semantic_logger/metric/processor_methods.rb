module SemanticLogger
  module Metric
    # Internal: the metric methods that the asynchronous Processor and the SyncProcessor share, so that
    # either one, as SemanticLogger::Logger.processor, is asked for metrics as it is asked for logs, and
    # a stand-in for it in a test, such as SemanticLogger::Test::CaptureLogEvents, captures them.
    #
    # Each processor gives the snapshots to its appenders itself, on the thread it writes to them on
    # (see Processor#log_metrics and SyncProcessor#log_metrics). Included in a class that answers
    # #appenders.
    module ProcessorMethods
      # Records the metric with the collector of the process (see Metric::Collector#record), which
      # returns false at once unless a metric appender is present. Never raises.
      def record_metric(kind, name, value, unit: nil, dimensions: nil, internal: false)
        Metric.collector.record(kind, name, value, unit: unit, dimensions: dimensions, internal: internal)
      end

      # Returns [true|false] whether the collector of the process collects the metrics recorded, while a
      # metric appender is present (see Metric::Collector#collecting?). Asked by a log call that has a
      # metric, before it reads it (see Base#collecting_metrics?).
      def collecting_metrics?
        Metric.collector.collecting?
      end

      # Returns [Numeric|nil] the shortest metrics interval of the appenders, or nil when none is a
      # metric appender (see Appenders#shortest_metrics_interval). Takes no lock. The collector asks it
      # at each tick, and stops collecting once it is nil (see Metric::Collector). Named apart from an
      # appender's own #metrics_interval, which says whether that appender is a metric appender.
      def shortest_metrics_interval
        appenders.shortest_metrics_interval
      end

      # Returns [true|false] whether any appender writes Semantic Logger's own metrics (see
      # Appenders#internal_metrics?). Takes no lock.
      def internal_metrics?
        appenders.internal_metrics?
      end

      # Yields each queue of the pipeline, by the object that owns it, which keeps its counts for as long
      # as it lives, with its name and its cumulative counts (see Subscriber#queue_log_counts): first the main
      # queue, owned by this processor, whose name is nil, then that of each appender with a queue of its
      # own (see Appenders#each_queue_log_counts). Takes no lock. Read for Semantic Logger's own metrics (see
      # Metric::InternalMetrics).
      def each_queue_log_counts(&)
        yield self, nil, queue_log_counts
        appenders.each_queue_log_counts(&)
      end
    end
  end
end
