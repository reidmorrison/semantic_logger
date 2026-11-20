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
    class CaptureLogEvents < SemanticLogger::Subscriber
      attr_accessor :events

      # Returns [Array<SemanticLogger::Metric::Snapshot>] the snapshots of metrics given to it while it
      # stands in for the processor (see #log_metrics).
      attr_reader :snapshots

      # By default collect all log levels, and collect metric only log events.
      def initialize(level: :trace, metrics: true)
        super
        @events    = []
        @snapshots = []
        @created   = ObjectSpace::WeakMap.new
      end

      # Standing in for a logger, it runs the `on_log` subscribers for the log events it created, as a
      # logger does. Log events from a logger, received as the processor or an appender, already
      # went through them. A log event built elsewhere and passed to `#log` is captured without
      # running them, since it cannot be told apart from one received from a logger.
      def log(log)
        Logger.call_subscribers(log) if @created.key?(log)
        @events << log
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

      def clear
        @events.clear
        @snapshots.clear
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
