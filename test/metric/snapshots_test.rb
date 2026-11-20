require_relative "../test_helper"

module Metric
  class SnapshotsTest < Minitest::Test
    # A metric appender that also implements #batch, which it is not batched for by default.
    class BatchingMetricAppender < InMemoryMetricAppender
      def batch(logs)
        logs
      end
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

      describe "#flush" do
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
        it "writes the snapshot it holds" do
          aggregator.record(:counter, "ticks", 1)
          appender.log_metrics(aggregator.collect(start_time + 1))
          appender.close

          assert_equal ["ticks"], appender.points.map(&:name)
        end
      end

      describe "Appenders#metrics_interval" do
        it "is the shortest interval of the metric appenders" do
          appenders << InMemoryAppender.new

          assert_nil appenders.metrics_interval

          appenders << InMemoryMetricAppender.new(interval: 30)
          appenders << InMemoryMetricAppender.new(interval: 10)

          assert_equal 10, appenders.metrics_interval
        end
      end

      describe "Appender.factory" do
        it "does not batch a metric appender by default" do
          appender = SemanticLogger::Appender.factory(metric: BatchingMetricAppender.new)

          assert_kind_of BatchingMetricAppender, appender
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
