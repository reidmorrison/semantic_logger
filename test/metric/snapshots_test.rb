require_relative "../test_helper"

module Metric
  class SnapshotsTest < Minitest::Test
    # A metric appender that also implements #batch, which it is not batched for by default.
    class BatchingMetricAppender < InMemoryMetricAppender
      def batch(logs)
        logs
      end
    end

    # A metric appender whose writes fail with `failure` while it is set, keeping every snapshot it is asked
    # to write in #attempts. Says whether a failure is retryable, and whether it was never sent, as told.
    class FlakyMetricAppender < InMemoryMetricAppender
      attr_accessor :failure, :retryable, :never_sent
      attr_reader :attempts

      def initialize(**)
        @attempts = []
        super
      end

      def write_metrics(snapshot)
        @attempts << snapshot
        raise failure if failure

        super
      end

      def metrics_retryable?(_exception) = retryable

      def not_sent?(_exception) = never_sent
    end

    # An appender that records that it was flushed, closed, and reopened, to derive a metric appender from.
    class LifecycleAppender < SemanticLogger::Subscriber
      attr_reader :calls

      def initialize(**)
        @calls = []
        super
      end

      def flush
        @calls << :flush
        :flushed
      end

      def close
        @calls << :close
        :closed
      end

      def reopen
        @calls << :reopen
        :reopened
      end
    end

    # A metric appender derived from LifecycleAppender.
    class LifecycleMetricAppender < LifecycleAppender
      include SemanticLogger::Metric::Snapshots

      attr_accessor :failure

      def write_metrics(_snapshot)
        raise failure if failure
      end
    end

    # A metric appender that writes log entries of its own, at the level it is given.
    class LevelMetricAppender < InMemoryMetricAppender
      private

      def refused_log_entry_options = super - [:level]
    end

    describe SemanticLogger::Metric::Snapshots do
      let(:start_time) { Time.at(1_000) }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new(now: start_time) }
      let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
      let(:appenders) { SemanticLogger::Appenders.new(capture_logger) }
      let(:appender) { InMemoryMetricAppender.new }

      # Records a count of 1 for "ticks", then gives the snapshot up to `seconds` after the start to the appenders.
      def tick(seconds)
        aggregator.record(:counter, "ticks", 1)
        appenders.log_metrics(aggregator.collect(start_time + seconds))
      end

      describe "options" do
        it "has an interval of 60 seconds and leaves out internal metrics by default" do
          assert_equal 60, appender.metrics_interval
          refute_predicate appender, :internal_metrics?
        end

        it "takes an interval and internal_metrics" do
          appender = InMemoryMetricAppender.new(interval: 10, internal_metrics: true)

          assert_equal 10, appender.metrics_interval
          assert_predicate appender, :internal_metrics?
        end

        it "passes the other options on to the appender" do
          appender = InMemoryMetricAppender.new(interval: 5, application: "metrics app")

          assert_equal "metrics app", appender.application
        end

        it "rejects an interval that is not a positive number of seconds" do
          [0, -1, "60", Float::INFINITY, Float::NAN].each do |interval|
            error = assert_raises(ArgumentError) { InMemoryMetricAppender.new(interval: interval) }

            assert_includes error.message, "interval: must be a positive number of seconds"
          end
        end

        it "takes no log entries" do
          refute appender.should_log?(SemanticLogger::Log.new("Test", :error))
        end

        it "is not a metric appender without the module" do
          assert_nil InMemoryAppender.new.metrics_interval
        end

        it "refuses the options for log entries, naming each one" do
          {
            {level: :info}                    => "level:",
            {filter: /Name/}                  => "filter:",
            {formatter: :json}                => "formatter:",
            {level: :info, formatter: :color} => "level:, formatter:"
          }.each_pair do |options, names|
            error = assert_raises(ArgumentError) { InMemoryMetricAppender.new(**options) }

            assert_includes error.message,
                            "InMemoryMetricAppender takes no #{names}, since a metric appender takes no log entries"
          end
        end

        it "refuses a formatter block" do
          error = assert_raises(ArgumentError) { InMemoryMetricAppender.new { |log, _logger| log.message } }

          assert_includes error.message, "InMemoryMetricAppender takes no formatter block, since"
          assert_includes error.message, "the appender writes them in the format of its destination"
          assert_includes error.message, "Remove it."
        end

        it "says what to do instead" do
          error = assert_raises(ArgumentError) { InMemoryMetricAppender.new(level: :warn, filter: /A/) }

          assert_includes error.message, "metrics are recorded whatever the log level"
          assert_includes error.message, "every metric recorded is written"
          assert_includes error.message, "Remove them."
        end

        it "takes those options when nil, since they set nothing" do
          appender = InMemoryMetricAppender.new(level: nil, filter: nil, formatter: nil)

          assert_equal 60, appender.metrics_interval
        end

        it "takes level: in an appender that writes log entries of its own" do
          appender = LevelMetricAppender.new(level: :info)

          assert_equal :info, appender.level
          assert_raises(ArgumentError) { LevelMetricAppender.new(formatter: :json) }
        end

        it "raises NotImplementedError from #write_metrics until the appender implements it" do
          appender = Class.new(SemanticLogger::Subscriber) { include SemanticLogger::Metric::Snapshots }.new

          assert_raises(NotImplementedError) { appender.write_metrics(aggregator.collect) }
        end
      end

      describe "#log_metrics" do
        it "holds each snapshot until its interval has passed, then writes them merged" do
          appender = InMemoryMetricAppender.new(interval: 3)
          appenders << appender
          tick(1)
          tick(2)

          assert_empty appender.snapshots

          tick(3)

          assert_equal 1, appender.snapshots.size
          snapshot = appender.snapshots.first

          assert_equal start_time, snapshot.start_time
          assert_equal start_time + 3, snapshot.end_time
          assert_equal 3, snapshot.points.first.value
        end

        it "writes each appender's snapshots at its own interval" do
          every_second       = InMemoryMetricAppender.new(interval: 1)
          every_three_second = InMemoryMetricAppender.new(interval: 3)
          appenders << every_second
          appenders << every_three_second
          (1..6).each { |seconds| tick(seconds) }

          assert_equal [1] * 6, every_second.points.map(&:value)
          assert_equal [3, 3], every_three_second.points.map(&:value)
          assert_equal [start_time, start_time + 3], every_three_second.snapshots.map(&:start_time)
          assert_equal [start_time + 3, start_time + 6], every_three_second.snapshots.map(&:end_time)
        end

        it "writes once its interval ends nearer now than at the next snapshot" do
          appender = InMemoryMetricAppender.new(interval: 3)
          appenders << appender
          tick(1)
          # 2.9 seconds since the start, while the next snapshot, as long as this one, would end 1.9 seconds later.
          tick(2.9)

          assert_equal 1, appender.snapshots.size
        end

        it "merges a snapshot that arrives after a later one" do
          appender = InMemoryMetricAppender.new(interval: 3)
          aggregator.record(:counter, "ticks", 1)
          earlier = aggregator.collect(start_time + 1)
          aggregator.record(:counter, "ticks", 1)
          later = aggregator.collect(start_time + 2)
          appender.log_metrics(later)
          appender.log_metrics(earlier)
          appender.flush
          snapshot = appender.snapshots.first

          assert_equal start_time, snapshot.start_time
          assert_equal start_time + 2, snapshot.end_time
          assert_equal 2, snapshot.points.first.value
        end

        it "leaves out internal metrics unless asked for them" do
          internal = InMemoryMetricAppender.new(interval: 1, internal_metrics: true)
          appenders << appender
          appenders << internal
          aggregator.record(:counter, "semantic_logger.log.processed", 3, internal: true)
          aggregator.record(:counter, "users.signup", 1)
          snapshot = aggregator.collect(start_time + 1)
          appenders.log_metrics(snapshot)
          appenders.flush

          assert_equal ["users.signup"], appender.points.map(&:name)
          assert_equal ["semantic_logger.log.processed", "users.signup"], internal.points.map(&:name).sort
        end

        it "does not write a snapshot without points" do
          appender = InMemoryMetricAppender.new(interval: 1)
          appenders << appender
          appenders.log_metrics(aggregator.collect(start_time + 2))

          assert_empty appender.snapshots
        end

        it "is not given to an appender that is not a metric appender" do
          plain = InMemoryAppender.new
          appenders << plain
          appenders << appender
          tick(1)

          refute_respond_to plain, :log_metrics
          assert_empty capture_logger.events
        end

        it "reports an appender that fails, and still gives the snapshot to the others" do
          failing = InMemoryMetricAppender.new
          failing.define_singleton_method(:log_metrics) { |_snapshot| raise "metrics boom" }
          appenders << failing
          appenders << appender
          tick(1)
          appenders.flush

          assert_equal ["ticks"], appender.points.map(&:name)
          assert(capture_logger.events.any? { |event| event.message.include?("Failed to write metrics to appender") })
        end
      end

      describe "writing again" do
        let(:appender) { FlakyMetricAppender.new(interval: 1) }
        let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }

        before do
          appender.logger = capture_logger
          appenders << appender
        end

        # The count of "ticks" in each snapshot that the appender was asked to write.
        def attempted_values = appender.attempts.map { |snapshot| snapshot.points.first.value }

        it "keeps a snapshot the appender says is worth writing again, and writes it merged with the next one" do
          appender.failure   = RuntimeError.new("429")
          appender.retryable = true
          tick(1)
          appender.failure = nil
          tick(2)
          snapshot = appender.snapshots.first

          assert_equal 1, appender.snapshots.size
          assert_equal start_time, snapshot.start_time
          assert_equal start_time + 2, snapshot.end_time
          assert_equal 2, snapshot.points.first.value
          assert_equal [:warn], capture_logger.events.map(&:level)
          assert_includes capture_logger.events.first.message, "writing them again with the next ones"
        end

        it "discards a snapshot the appender does not say is worth writing again" do
          appender.failure = RuntimeError.new("400")
          tick(1)
          appender.failure = nil
          tick(2)

          assert_equal [1], appender.points.map(&:value)
          assert_equal [:error], capture_logger.events.map(&:level)
          assert_includes capture_logger.events.first.message, "discarded them"
        end

        it "writes one again at most MAX_RESENDS times when the destination answers with a failure" do
          appender.failure   = RuntimeError.new("503")
          appender.retryable = true
          (1..5).each { |seconds| tick(seconds) }

          assert_equal 3, SemanticLogger::Metric::Snapshots::MAX_RESENDS
          assert_equal [1, 2, 3, 4, 1], attempted_values
          assert_equal %i[warn warn warn error warn], capture_logger.events.map(&:level)
        end

        it "keeps one that was never sent for as long as it takes, without counting it" do
          appender.failure    = RuntimeError.new("connection refused")
          appender.retryable  = true
          appender.never_sent = true
          (1..6).each { |seconds| tick(seconds) }
          appender.failure = nil
          tick(7)

          assert_equal [7], appender.points.map(&:value)
          assert_equal start_time, appender.snapshots.first.start_time
        end

        it "starts counting again once one is written" do
          appender.failure   = RuntimeError.new("503")
          appender.retryable = true
          (1..3).each { |seconds| tick(seconds) }
          appender.failure = nil
          tick(4)
          appender.failure = RuntimeError.new("503")
          (5..8).each { |seconds| tick(seconds) }

          assert_equal [4], appender.points.map(&:value)
          assert_equal [1, 2, 3, 4, 1, 2, 3, 4], attempted_values
        end

        it "discards one that was never sent once it would hold more than MAX_KEPT_POINTS points" do
          appender.failure    = RuntimeError.new("connection refused")
          appender.retryable  = true
          appender.never_sent = true
          max    = SemanticLogger::Metric::Snapshots::MAX_KEPT_POINTS
          points = Array.new(max) { |i| SemanticLogger::Metric::Snapshot::Point.new(kind: :counter, name: "n#{i}", value: 1) }
          tick(1)
          appenders.log_metrics(
            SemanticLogger::Metric::Snapshot.new(start_time: start_time + 1, end_time: start_time + 2, points: points)
          )

          assert_equal 10_000, max
          assert_equal [1, max + 1], appender.attempts.map(&:size)
          assert_equal %i[warn error], capture_logger.events.map(&:level)
          assert_includes capture_logger.events.last.message, "discarded them, since they would have been kept"
          appender.failure = nil
          tick(3)

          assert_equal([[start_time + 1, 1]], appender.snapshots.map { |written| [written.start_time, written.size] })
        end

        it "discards one that was never sent once it would span more than MAX_KEPT_SECONDS" do
          appender.failure    = RuntimeError.new("connection refused")
          appender.retryable  = true
          appender.never_sent = true
          max                 = SemanticLogger::Metric::Snapshots::MAX_KEPT_SECONDS
          tick(1)
          tick(max)
          tick(max + 1)

          assert_equal 3600, max
          assert_equal %i[warn warn error], capture_logger.events.map(&:level)
          appender.failure = nil
          tick(max + 2)

          assert_equal [start_time + max + 1], appender.snapshots.map(&:start_time)
        end

        it "writes the snapshot it keeps, with the one it holds, once at a flush, and discards it when that fails" do
          other = FlakyMetricAppender.new(interval: 3)
          other.logger = capture_logger
          appenders << other
          appender.failure   = RuntimeError.new("503")
          appender.retryable = true
          other.failure      = appender.failure
          other.retryable    = true
          tick(1)
          appenders.flush

          assert_equal 2, appender.attempts.size
          assert_equal 1, other.attempts.size
          assert_equal %i[warn error error], capture_logger.events.map(&:level) - [:trace]

          appender.failure = nil
          appenders.flush

          assert_empty appender.snapshots
        end
      end

      describe "in a child process" do
        let(:appender) { FlakyMetricAppender.new(interval: 3) }

        # Holds a snapshot and keeps another one, then runs the block as though in a child process, started
        # by Process.daemon or not, and returns the snapshots written there at a flush.
        def written_in_child(daemon:)
          appender.failure   = RuntimeError.new("503")
          appender.retryable = true
          appender.logger    = SemanticLogger::Test::CaptureLogEvents.new
          appenders << appender
          (1..4).each { |seconds| tick(seconds) }
          appender.failure = nil
          ::Process.stub(:pid, ::Process.pid + 1) do
            SemanticLogger::CoreExt::Process.stub(:daemon?, daemon) do
              yield
              appender.flush
            end
          end
          appender.snapshots
        end

        it "discards the snapshots inherited from the parent once reopened" do
          assert_empty(written_in_child(daemon: false) { appender.reopen })
        end

        it "discards them in a child that was not reopened" do
          assert_empty(written_in_child(daemon: false) { :not_reopened })
        end

        it "keeps them in a process started by Process.daemon" do
          snapshots = written_in_child(daemon: true) { appender.reopen }

          assert_equal [4], snapshots.flat_map(&:points).map(&:value)
        end

        it "asks the appender, once, to forget whatever else it carries over from the parent" do
          forgotten = []
          appender.define_singleton_method(:forget_parent_state) { forgotten << ::Process.pid }
          written_in_child(daemon: false) { appender.reopen }

          assert_equal [::Process.pid + 1], forgotten
        end

        it "does not ask the appender to forget it in a process started by Process.daemon" do
          forgotten = []
          appender.define_singleton_method(:forget_parent_state) { forgotten << ::Process.pid }
          written_in_child(daemon: true) { appender.reopen }

          assert_empty forgotten
        end
      end

      describe "#reopen" do
        it "reopens the appender it is included in" do
          appender = LifecycleMetricAppender.new

          assert_equal :reopened, appender.reopen
          assert_equal [:reopen], appender.calls
        end

        it "returns true for an appender that has no #reopen" do
          assert appender.reopen
        end
      end

      describe "#flush" do
        it "flushes the appender after writing fails" do
          appender = LifecycleMetricAppender.new
          appender.logger  = SemanticLogger::Test::CaptureLogEvents.new
          appender.failure = RuntimeError.new("boom")
          aggregator.record(:counter, "ticks", 1)
          appender.log_metrics(aggregator.collect(start_time + 1))

          assert_equal :flushed, appender.flush
          assert_equal [:flush], appender.calls
          assert_equal [:error], appender.logger.events.map(&:level)
        end

        it "flushes the appender before it raises what writing raised past its rescue" do
          appender = LifecycleMetricAppender.new
          appender.failure = Exception.new("hard stop")
          aggregator.record(:counter, "ticks", 1)
          appender.log_metrics(aggregator.collect(start_time + 1))

          assert_raises(Exception) { appender.flush }
          assert_equal [:flush], appender.calls
        end

        it "writes the snapshot it holds, then flushes the appender" do
          flushed = false
          appender.define_singleton_method(:flush) do
            super()
            flushed = snapshots.size
          end
          appenders << appender
          tick(1)

          assert_empty appender.snapshots

          appenders.flush

          assert_equal 1, flushed
          appenders.flush

          assert_equal 1, appender.snapshots.size
        end
      end

      describe "#close" do
        it "closes the appender after writing fails, such as to close its connection" do
          appender = LifecycleMetricAppender.new
          appender.logger  = SemanticLogger::Test::CaptureLogEvents.new
          appender.failure = RuntimeError.new("boom")
          aggregator.record(:counter, "ticks", 1)
          appender.log_metrics(aggregator.collect(start_time + 1))

          assert_equal :closed, appender.close
          assert_equal [:close], appender.calls
        end

        it "closes the appender before it raises what writing raised past its rescue" do
          appender = LifecycleMetricAppender.new
          appender.failure = Exception.new("hard stop")
          aggregator.record(:counter, "ticks", 1)
          appender.log_metrics(aggregator.collect(start_time + 1))

          assert_raises(Exception) { appender.close }
          assert_equal [:close], appender.calls
        end

        it "writes the snapshot it holds" do
          aggregator.record(:counter, "ticks", 1)
          appender.log_metrics(aggregator.collect(start_time + 1))
          appender.close

          assert_equal ["ticks"], appender.points.map(&:name)
        end
      end

      describe "Appender::Async#log_metrics" do
        it "reports what the appender raises, whatever its class, and carries on" do
          failing = InMemoryMetricAppender.new
          failing.define_singleton_method(:log_metrics) { |_snapshot| raise NotImplementedError, "no metrics" }
          failing.logger = capture_logger
          async          = SemanticLogger::Appender::Async.new(appender: failing)
          aggregator.record(:counter, "ticks", 1)
          async.log_metrics(aggregator.collect(start_time + 1))
          async.flush

          assert_predicate async, :active?
          assert(capture_logger.events.any? { |event| event.message.include?("Failed to write metrics to appender") })
        ensure
          async&.close
        end

        it "gives the appender one snapshot at a time once its worker thread has stopped, and flushes it between" do
          inside = 0
          most   = 0
          given  = Queue.new
          slow   = InMemoryMetricAppender.new(interval: 1)
          slow.define_singleton_method(:write_metrics) do |snapshot|
            inside += 1
            most    = [most, inside].max
            sleep 0.02
            inside -= 1
            given << snapshot
          end
          async = SemanticLogger::Appender::Async.new(appender: slow)
          async.close
          (1..3).each do |seconds|
            aggregator.record(:counter, "ticks", 1)
            async.log_metrics(aggregator.collect(start_time + seconds))
          end
          aggregator.record(:counter, "ticks", 1)
          slow.log_metrics(aggregator.collect(start_time + 3.5))
          flushing = Thread.new { slow.flush }

          # The snapshots handed over after the close each run on a thread of their own, which may start
          # after the snapshot given directly, as on Ruby 3.2: that one is then merged into a later write,
          # so there can be fewer writes than snapshots, but every tick is written, one write at a time.
          ticks = 0
          while ticks < 4 && (snapshot = given.pop(timeout: 2))
            ticks += snapshot.points.sum(&:value)
          end
          flushing.join(2)

          assert_equal 4, ticks
          assert_equal 1, most
        end
      end

      describe "Appenders#shortest_metrics_interval" do
        it "is the shortest interval of the metric appenders" do
          appenders << InMemoryAppender.new

          assert_nil appenders.shortest_metrics_interval

          appenders << InMemoryMetricAppender.new(interval: 30)
          appenders << InMemoryMetricAppender.new(interval: 10)

          assert_equal 10, appenders.shortest_metrics_interval
        end
      end

      describe "Appender.factory" do
        it "does not batch a metric appender by default" do
          appender = SemanticLogger::Appender.factory(metric: BatchingMetricAppender.new)

          assert_kind_of BatchingMetricAppender, appender
          refute_predicate appender, :batch_by_default?
        end

        it "refuses to batch a metric appender" do
          error = assert_raises(ArgumentError) do
            SemanticLogger::Appender.factory(metric: BatchingMetricAppender.new, batch: true)
          end

          assert_includes error.message, "a metric appender takes no log entries"
        end

        it "forwards the metrics interval of a metric appender added with async: true" do
          appender = SemanticLogger::Appender.factory(metric: InMemoryMetricAppender.new(interval: 7), async: true)

          assert_kind_of SemanticLogger::Appender::Async, appender
          assert_equal 7, appender.metrics_interval
        ensure
          appender&.close
        end
      end
    end
  end
end
