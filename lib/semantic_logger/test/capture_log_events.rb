module SemanticLogger
  module Test
    # Logging class to captures all logging events in memory.
    #
    # Example:
    #
    #   class UserTest < ActiveSupport::TestCase
    #     describe User do
    #       let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }
    #       let(:user) { User.new }
    #
    #       it "logs message" do
    #         user.stub(:logger, logger) do
    #           user.enable!
    #         end
    #         assert log = logger.events.first
    #         assert_equal "Hello World", log.message
    #         assert_equal :info, log.level
    #       end
    #     end
    #   end
    #
    # It also captures the metric calls (`increment`, `time`, and `record`), and the `metric:` of log
    # and `measure_*` calls at every level, in #metric_events, as they are made, before they are
    # aggregated, whether or not a metric appender is present: when it stands in for a logger, as
    # above, and when it stands in for the processor, as
    # SemanticLogger::Test::Minitest#semantic_logger_metrics does.
    #
    #   user.stub(:logger, logger) { user.enable! }
    #   assert metric = logger.metric_events.first
    #   assert_equal "users.enabled", metric.name
    class CaptureLogEvents < SemanticLogger::Subscriber
      # Captures the backtrace of the code that logged each event at :error and above, as the appender
      # of an error service does, so that a test can assert it (see Log#capture_backtrace!).
      ERROR_INDEX = Levels.index(:error)
      private_constant :ERROR_INDEX

      # Shareable, so that it runs for the events logged in a Ractor other than the main one too.
      CAPTURE_BACKTRACE = Utils.make_shareable(lambda do |log|
        log.capture_backtrace! if log.level_index >= ERROR_INDEX
      end)

      # CAPTURE_BACKTRACE, as its source captures (see #source_captures).
      CAPTURES = [CAPTURE_BACKTRACE].freeze
      private_constant :CAPTURES

      attr_accessor :events

      # Returns [Array<SemanticLogger::Metric::Snapshot>] the snapshots of metrics given to it while it
      # stands in for the processor (see #log_metrics).
      attr_reader :snapshots

      # Returns [Array<SemanticLogger::Test::MetricEvent>] the metric calls captured.
      attr_reader :metric_events

      # By default collect all log levels, and collect metric only log events.
      def initialize(level: :trace, metrics: true)
        super
        @events           = []
        @snapshots        = []
        @metric_events    = []
        @metric_validator = Metric::Validator.new
        @created          = ObjectSpace::WeakMap.new
      end

      # Standing in for a logger, it runs the `on_log` subscribers for the log events it created, as a
      # logger does. Log events from a logger, received as the processor or an appender, already
      # went through them. A log event built elsewhere and passed to `#log` is captured without
      # running them, since it cannot be told apart from one received from a logger.
      #
      # It then runs its own source captures (see #source_captures), on the calling thread, which
      # logged the event when it stands in for a logger or for the processor. Added as an appender,
      # they ran when the event was logged, so they leave it as it is.
      def log(log)
        Logger.call_subscribers(log) if @created.key?(log)
        CAPTURE_BACKTRACE.call(log)
        @events << log
      end

      # Standing in for the processor, captures an event whose source captures already ran where it was
      # logged, such as in a Ractor other than the main one (see RactorReceiver), without capturing a
      # backtrace on this thread, which did not log it.
      def log_captured(log)
        @events << log
      end

      # Returns [Array<#call>] the capture of the backtrace of each event at :error and above (see
      # CAPTURE_BACKTRACE).
      def source_captures
        CAPTURES
      end

      # Supports batching of log events
      def batch(logs)
        logs.each { |log| self.log(log) }
      end

      # Standing in for the processor, it takes the snapshot of metrics of each interval, which the
      # processor would give to the metric appenders, and keeps it (see #snapshots).
      def log_metrics(snapshot)
        @snapshots << snapshot
        true
      end

      # Returns [Numeric]: standing in for the processor, it takes the snapshots of metrics (see
      # #log_metrics) at the default interval of a metric appender, so that the collector of metrics
      # carries on collecting while it stands in, rather than stop as it would were the processor to
      # have no metric appender (see Metric::Collector).
      def shortest_metrics_interval
        Metric::Snapshots::DEFAULT_INTERVAL
      end

      # Captures the metric call, standing in for a logger (see Base#increment) or for the processor
      # (see Processor#record_metric). Drops the ones that would not be recorded, after warning about
      # them, as the processor does (see Metric::Validator), so that a test sees just what would be
      # recorded.
      #
      # Semantic Logger's own metrics (`internal: true`) are not captured. The scope, the name of the
      # logger that made the call, is captured as the MetricEvent's scope when it stands in for the
      # processor, which a logger tells; standing in for a logger, it is not told, and captures none.
      # Like the processor, it never raises: a metric call that fails as it is captured, such as one
      # whose dimensions raise as they are read, is reported once for its name and not captured.
      #
      # Returns [true|false] whether it was captured.
      def record_metric(kind, name, value, unit: nil, dimensions: nil, internal: false, scope: nil)
        return false if internal

        accepted = @metric_validator.accept(kind, name, value, dimensions)
        return false unless accepted

        @metric_events << MetricEvent.new(
          kind: kind, name: accepted, value: value, unit: unit, dimensions: dimensions, scope: scope
        )
        true
      rescue StandardError => e
        @metric_validator.report_failure(kind, name, e)
      end

      # Returns [true]: it captures the metric calls whether or not a metric appender is present, so a
      # log call that has a metric records it at every level (see Base#collecting_metrics?), when it
      # stands in for a logger or for the processor.
      def collecting_metrics?
        true
      end

      # Discards the log events, snapshots, and metric calls captured.
      def clear
        @events.clear
        @snapshots.clear
        @metric_events.clear
      end

      # Returns [false]: standing in for the processor, it holds no lock, so another thread never
      # waits for the calling thread to return from a call to it.
      def current_thread_inside?
        false
      end

      def to_h
        events.map(&:to_h)
      end

      private

      # Remember each log event created while standing in for a logger.
      def new_log(...)
        log = super
        @created[log] = true
        log
      end

      # Without a level of its own, follow the global default level the way a logger does,
      # so that `SemanticLogger.silence` applies.
      def fallback_level_index
        SemanticLogger.default_level_index
      end
    end
  end
end
