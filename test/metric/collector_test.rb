require_relative "../test_helper"
require_relative "../signal_trap_helper"
require_relative "../forked_child_helper"

module Metric
  class CollectorTest < Minitest::Test
    # Stands in for the processor of a collector: answers the metrics interval it is given, and keeps
    # the snapshots it is given.
    class FakeProcessor
      attr_accessor :metrics_interval
      attr_reader :snapshots

      def initialize(metrics_interval)
        @metrics_interval = metrics_interval
        @snapshots        = Queue.new
      end

      def log_metrics(snapshot)
        @snapshots << snapshot
      end

      def logger
        SemanticLogger::Processor.logger
      end
    end

    describe SemanticLogger::Metric::Collector do
      include SignalTrapHelper
      include ForkedChildHelper

      let(:collector) { SemanticLogger::Metric.collector }
      let(:appender) { InMemoryMetricAppender.new }

      def record(name, value = 1, **args)
        SemanticLogger::Logger.processor.record_metric(:counter, name, value, **args)
      end

      # Waits for the thread to end, at most a second.
      def await_end(thread)
        thread&.join(1)

        refute_predicate thread, :alive?, "the collector's thread should have ended"
      end

      after do
        SemanticLogger.appenders.dup.each do |added|
          SemanticLogger.remove_appender(added) if added.metrics_interval
        end
      end

      describe "without a metric appender" do
        it "does not collect, and drops what is recorded" do
          refute_predicate collector, :collecting?
          refute record("users.signup")
          SemanticLogger.add_appender(appender: InMemoryAppender.new).then do |plain|
            refute_predicate collector, :collecting?
          ensure
            SemanticLogger.remove_appender(plain)
          end
        end
      end

      describe "with a metric appender" do
        it "starts collecting once one is added, and stops once the last one is removed" do
          SemanticLogger.add_appender(metric: appender)
          other = SemanticLogger.add_appender(metric: InMemoryMetricAppender.new)
          thread = collector.thread

          assert_predicate collector, :collecting?
          assert_predicate thread, :alive?

          SemanticLogger.remove_appender(other)

          assert_predicate collector, :collecting?

          SemanticLogger.remove_appender(appender)

          refute_predicate collector, :collecting?
          refute record("users.signup")
          await_end(thread)
        end

        it "gives the metrics to the metric appenders as they are flushed, and to no other appender" do
          plain            = SemanticLogger.add_appender(appender: InMemoryAppender.new)
          given            = []
          plain.define_singleton_method(:log_metrics) { |snapshot| given << snapshot }
          original_logger  = SemanticLogger.appenders.logger
          capture_logger   = SemanticLogger::Test::CaptureLogEvents.new
          SemanticLogger.appenders.logger = capture_logger
          SemanticLogger.add_appender(metric: appender)

          assert record("users.signup", 2, dimensions: {plan: "free"})
          SemanticLogger.flush
          point = appender.points.first

          assert_equal 1, appender.snapshots.size
          assert_equal "users.signup", point.name
          assert_equal 2, point.value
          assert_equal({plan: "free"}, point.dimensions)
          assert_empty given
          assert_empty(capture_logger.events.reject { |event| event.level == :trace })
        ensure
          SemanticLogger.appenders.logger = original_logger if original_logger
          SemanticLogger.remove_appender(plain)
        end

        it "gives the metrics to a metric appender added with async: true" do
          async = SemanticLogger.add_appender(metric: appender, async: true)

          assert_kind_of SemanticLogger::Appender::Async, async
          assert_predicate collector, :collecting?

          record("users.signup")
          SemanticLogger.flush

          assert_equal ["users.signup"], appender.points.map(&:name)
        end

        it "has a metric appender write what it holds, with what was recorded since, before it is removed" do
          SemanticLogger.add_appender(metric: appender)
          record("users.signup")
          SemanticLogger.remove_appender(appender)

          assert_equal ["users.signup"], appender.points.map(&:name)
        end

        it "reports a metric appender that fails, and still gives the metrics to the others" do
          failing = InMemoryMetricAppender.new
          failing.define_singleton_method(:write_metrics) { |_snapshot| raise "metrics boom" }
          original_logger = SemanticLogger.appenders.logger
          capture_logger  = SemanticLogger::Test::CaptureLogEvents.new
          SemanticLogger.appenders.logger = capture_logger
          SemanticLogger.add_appender(metric: failing)
          SemanticLogger.add_appender(metric: appender)
          record("users.signup")
          SemanticLogger.flush

          assert_equal ["users.signup"], appender.points.map(&:name)
          assert(capture_logger.events.any? { |event| event.message.include?("Failed to flush appender") })
        ensure
          SemanticLogger.appenders.logger = original_logger if original_logger
        end

        it "skips collecting in a signal trap, and delivers what it holds at the next flush" do
          SemanticLogger.add_appender(metric: appender)
          record("users.signup")
          result = in_signal_trap do
            record("in.trap")
            SemanticLogger.flush
          end

          refute_kind_of Exception, result
          SemanticLogger.flush

          assert_equal ["in.trap", "users.signup"], appender.points.map(&:name).sort
        end

        it "discards the metrics inherited from the parent in a forked child, and keeps collecting there" do
          SemanticLogger.add_appender(metric: appender)
          record("in.parent")
          output = in_forked_child do
            record("in.child")
            thread = collector.thread
            SemanticLogger.flush
            "#{appender.points.map(&:name).join(',')} #{thread&.alive?}"
          end

          assert_equal "in.child true", output
          SemanticLogger.flush

          assert_equal ["in.parent"], appender.points.map(&:name)
        end
      end

      describe "with its own processor" do
        let(:collector) { SemanticLogger::Metric::Collector.new }
        let(:processor) { FakeProcessor.new(60) }

        # Runs the block while the collector's processor, SemanticLogger::Logger.processor, is the fake one.
        # Stops the collector's thread afterwards.
        def with_processor(processor = self.processor, &)
          SemanticLogger::Logger.stub(:processor, processor, &)
        ensure
          processor.metrics_interval = nil
          threads = [collector.thread].compact
          collector.check
          threads.each { |thread| thread.join(1) || thread.kill }
        end

        it "collects at each tick of the shortest interval, and stops once there is none" do
          processor.metrics_interval = 0.01
          with_processor do
            collector.start
            collector.record(:counter, "ticks", 1)
            thread = collector.thread

            refute_nil processor.snapshots.pop(timeout: 1), "the collector should have delivered a snapshot"
            refute_nil processor.snapshots.pop(timeout: 1), "the collector should have delivered a second snapshot"

            processor.metrics_interval = nil
            collector.check
            await_end(thread)

            refute_predicate collector, :collecting?
          end
        end

        it "delivers a snapshot of what was recorded up to the given time" do
          with_processor do
            collector.start
            collector.record(:histogram, "upload.size", 1024, unit: "By")
            collector.record(:counter, "internal.count", 1, internal: true)
            now = Time.now + 1

            assert collector.deliver(now)
            snapshot = processor.snapshots.pop(timeout: 0)

            assert_equal now, snapshot.end_time
            assert_equal %w[internal.count upload.size], snapshot.points.map(&:name).sort
          end
        end

        it "gives the snapshot to whichever processor is current, such as after sync!" do
          sync_processor = FakeProcessor.new(60)
          with_processor do
            collector.start
            collector.record(:counter, "before", 1)
            collector.deliver
          end
          with_processor(sync_processor) do
            collector.start
            collector.record(:counter, "after", 1)
            collector.deliver
          end

          assert_equal ["before"], processor.snapshots.pop(timeout: 0).points.map(&:name)
          assert_equal ["after"], sync_processor.snapshots.pop(timeout: 0).points.map(&:name)
        end

        it "does not deliver when not collecting" do
          with_processor do
            refute collector.deliver

            assert_equal 0, processor.snapshots.size
          end
        end

        it "starts afresh, without what was recorded before collecting stopped" do
          with_processor do
            collector.start
            collector.record(:counter, "before", 1)
            processor.metrics_interval = nil
            thread = collector.thread
            collector.check
            await_end(thread)
            processor.snapshots.clear
            processor.metrics_interval = 60
            collector.start
            collector.record(:counter, "after", 1)
            collector.deliver

            assert_equal ["after"], processor.snapshots.pop(timeout: 0).points.map(&:name)
          end
        end

        describe "#reopen" do
          # Records "inherited", then reopens as though in a child process, started by Process.daemon or
          # not, and returns the names delivered there.
          def names_in_child(daemon:)
            with_processor do
              collector.start
              collector.record(:counter, "inherited", 1)
              parent_thread = collector.thread
              ::Process.stub(:pid, ::Process.pid + 1) do
                collector.daemonized if daemon
                collector.reopen

                refute_same parent_thread, collector.thread
                assert_predicate collector.thread, :alive?
                collector.deliver
              ensure
                parent_thread&.kill
              end
              processor.snapshots.pop(timeout: 0).points.map(&:name)
            end
          end

          it "discards the metrics inherited from the parent in a forked child, and starts a thread" do
            assert_empty names_in_child(daemon: false)
          end

          it "keeps them in a process started by Process.daemon" do
            assert_equal ["inherited"], names_in_child(daemon: true)
          end

          it "starts the thread again in the same process once it has ended" do
            with_processor do
              collector.start
              thread = collector.thread
              thread.kill.join
              collector.reopen

              refute_same thread, collector.thread
              assert_predicate collector.thread, :alive?
            end
          end
        end
      end
    end
  end
end
