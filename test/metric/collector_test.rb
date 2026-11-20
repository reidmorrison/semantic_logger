require_relative "../test_helper"
require_relative "../signal_trap_helper"
require_relative "../forked_child_helper"

module Metric
  class CollectorTest < Minitest::Test
    # Stands in for the processor of a collector: answers the metrics interval it is given, that no
    # metric appender writes Semantic Logger's own metrics, and keeps the snapshots it is given.
    class FakeProcessor
      attr_accessor :shortest_metrics_interval
      attr_reader :snapshots, :logger

      def initialize(shortest_metrics_interval)
        @shortest_metrics_interval = shortest_metrics_interval
        @snapshots        = Queue.new
        @logger           = SemanticLogger::Test::CaptureLogEvents.new
      end

      def log_metrics(snapshot)
        @snapshots << snapshot
      end

      def internal_metrics? = false
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
          assert_equal({"plan" => "free"}, point.dimensions)
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
          capture_logger = SemanticLogger::Test::CaptureLogEvents.new
          failing.logger = capture_logger
          SemanticLogger.add_appender(metric: failing)
          SemanticLogger.add_appender(metric: appender)
          record("users.signup")
          SemanticLogger.flush

          assert_equal ["users.signup"], appender.points.map(&:name)
          assert(capture_logger.events.any? { |event| event.message.include?("Failed to write the metrics") })
        end

        it "records Semantic Logger's own metrics for the appenders that write them" do
          internal = SemanticLogger.add_appender(metric: InMemoryMetricAppender.new(internal_metrics: true))
          SemanticLogger.add_appender(metric: appender)

          assert SemanticLogger::Logger.processor.record_metric(:counter, "semantic_logger.test", 1, internal: true)
          SemanticLogger.flush

          assert_empty appender.points
          assert_equal [true], internal.points.map(&:internal?)
        end

        it "has a metric appender removed on the processor's thread write what it holds, with what was recorded" do
          remover = InMemoryAppender.new
          metric  = appender
          removed = Queue.new
          remover.define_singleton_method(:log) do |log|
            if log.message == "remove"
              SemanticLogger.remove_appender(metric)
              removed << metric.points.map(&:name)
            end
            super(log)
          end
          SemanticLogger.add_appender(appender: remover)
          SemanticLogger.add_appender(metric: appender)
          record("users.signup")
          SemanticLogger["Test"].info("remove")

          # Written as it was removed, without a flush that would have collected them first.
          assert_equal ["users.signup"], removed.pop(timeout: 2)
          assert_equal ["users.signup"], appender.points.map(&:name)
          refute_includes SemanticLogger.appenders, appender
        ensure
          SemanticLogger.remove_appender(remover)
        end

        it "keeps collecting while the processor is a stand-in that captures log events, which takes the snapshots" do
          SemanticLogger.add_appender(metric: appender)
          thread  = collector.thread
          capture = SemanticLogger::Test::CaptureLogEvents.new
          SemanticLogger::Logger.stub(:processor, capture) do
            collector.record(:counter, "while.stubbed", 1)

            assert collector.deliver
            # As when a metric appender is added: the thread asks the stand-in for the interval.
            collector.start
            thread.join(0.05)

            assert_predicate collector, :collecting?
            assert_predicate thread, :alive?
          end
          collector.record(:counter, "after.stub", 1)
          SemanticLogger.flush

          assert_equal ["while.stubbed"], capture.snapshots.flat_map(&:points).map(&:name)
          assert_equal ["after.stub"], appender.points.map(&:name)
        end

        it "stops collecting once the last metric appender is gone, however it was removed" do
          SemanticLogger.add_appender(metric: InMemoryMetricAppender.new(interval: 0.01)).then do |metric|
            thread = collector.thread
            SemanticLogger.appenders.delete(metric)
            await_end(thread)
          end

          refute_predicate collector, :collecting?
        end

        it "stops collecting once the removal of the last metric appender, handed over to the processor, is done" do
          skip "only the asynchronous processor hands a removal over to its thread" if SemanticLogger.sync?

          metric  = SemanticLogger.add_appender(metric: appender)
          thread  = collector.thread
          remover = InMemoryAppender.new
          remover.define_singleton_method(:log) do |log|
            SemanticLogger.remove_appender(metric) if log.message == "remove"
            super(log)
          end
          remover = SemanticLogger.add_appender(appender: remover, async: true)
          begin
            SemanticLogger["Test"].info("remove")
            # The first flush has the appender remove the metric appender; the second one waits for that removal.
            SemanticLogger.flush
            SemanticLogger.flush
            await_end(thread)

            refute_predicate collector, :collecting?
            refute_includes SemanticLogger.appenders, metric
          ensure
            SemanticLogger.remove_appender(remover)
          end
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
        # Then, while the fake one is still in place, stops the collector, the `let` one unless the test
        # gives the one it built, and ends its thread, so that the thread never gives a snapshot to the
        # processor of a later test.
        def with_processor(processor = self.processor, collector: self.collector)
          SemanticLogger::Logger.stub(:processor, processor) do
            yield
          ensure
            stop_collector(collector, processor)
          end
        end

        def stop_collector(collector, processor)
          processor.shortest_metrics_interval = nil
          thread = collector.thread
          collector.check
          thread&.join(1) || thread&.kill&.join(1)
        end

        it "collects at each tick of the shortest interval, and stops once there is none" do
          processor.shortest_metrics_interval = 0.01
          with_processor do
            collector.start
            collector.record(:counter, "ticks", 1)
            thread = collector.thread

            refute_nil processor.snapshots.pop(timeout: 1), "the collector should have delivered a snapshot"
            refute_nil processor.snapshots.pop(timeout: 1), "the collector should have delivered a second snapshot"

            processor.shortest_metrics_interval = nil
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
            processor.shortest_metrics_interval = nil
            thread = collector.thread
            collector.check
            await_end(thread)
            processor.snapshots.clear
            processor.shortest_metrics_interval = 60
            collector.start
            collector.record(:counter, "after", 1)
            collector.deliver

            assert_equal ["after"], processor.snapshots.pop(timeout: 0).points.map(&:name)
          end
        end

        it "has its own metrics counted afresh when collecting starts again, not while it goes on" do
          internal  = SemanticLogger::Metric::InternalMetrics.new
          collector = SemanticLogger::Metric::Collector.new(internal_metrics: internal)
          restarts  = []
          internal.stub(:baseline, ->(restart: false) { restarts << restart }) do
            with_processor(collector: collector) do
              collector.start
              collector.start
              processor.shortest_metrics_interval = nil
              collector.check
              processor.shortest_metrics_interval = 60
              collector.start
            end
          end

          assert_equal [true, false, true], restarts
        end

        it "stops collecting at a tick that finds no interval, and collects again once started" do
          processor.shortest_metrics_interval = 0.01
          with_processor do
            collector.start
            thread = collector.thread
            processor.shortest_metrics_interval = nil
            await_end(thread)

            refute_predicate collector, :collecting?

            processor.snapshots.clear
            processor.shortest_metrics_interval = 0.01
            collector.start
            collector.record(:counter, "ticks", 1)
            snapshot = processor.snapshots.pop(timeout: 2)

            assert_equal ["ticks"], snapshot.points.map(&:name)
          end
        end

        it "reports a processor that fails to answer the interval, and keeps collecting" do
          failing = processor
          def failing.shortest_metrics_interval = raise("no interval")
          with_processor do
            collector.start
            thread = collector.thread
            thread.join(0.05)

            assert_predicate collector, :collecting?
            assert_predicate thread, :alive?
            assert(processor.logger.events.any? { |event| event.message == "Failed to collect metrics" })

            failing.singleton_class.remove_method(:shortest_metrics_interval)
            processor.shortest_metrics_interval = nil
          end
        end

        it "stops collecting when checked, once the processor has no metric appender" do
          with_processor do
            collector.start
            processor.shortest_metrics_interval = nil

            assert_predicate collector, :collecting?

            collector.check

            refute_predicate collector, :collecting?
          end
        end

        it "reports the records dropped beyond the limit of metric names once per interval, naming the first" do
          aggregator = SemanticLogger::Metric::Aggregator.new(name_limit: 1)
          collector  = SemanticLogger::Metric::Collector.new(aggregator: aggregator)
          with_processor(collector: collector) do
            collector.start
            2.times do
              collector.record(:counter, "users.signup", 1)
              collector.record(:counter, "user.42.signup", 1)
              collector.record(:counter, "user.43.signup", 1)
              collector.deliver
            end
          end
          events = processor.logger.events

          assert_equal 2, events.size
          assert_equal [:warn], events.map(&:level).uniq
          assert_includes events.first.message, "Dropped 2 metric records"
          assert_includes events.first.message, '"user.42.signup"'
          assert_includes events.first.message, "Put variable parts in dimensions: instead of the metric name"
        end

        it "reports the records of a metric name dropped for another kind or unit once per name" do
          with_processor do
            collector.start
            2.times do
              collector.record(:counter, "upload.size", 1)
              collector.record(:histogram, "upload.size", 10)
              collector.record(:histogram, "upload.time", 10, unit: "s")
              collector.record(:histogram, "upload.time", 10, unit: "ms")
              collector.deliver
            end
          end
          messages = processor.logger.events.map(&:message)

          assert_equal 2, messages.size
          assert(messages.any? { |message| message.include?('metric "upload.size"') })
          assert(messages.any? { |message| message.include?('metric "upload.time"') })
          assert(messages.all? { |message| message.include?("Give each metric name one kind and unit") })
        end

        it "reports a failure of its own once for every metric name, apart from the failures of recording" do
          aggregator = SemanticLogger::Metric::Aggregator.new
          aggregator.define_singleton_method(:record) { |*, **| raise NoMethodError, "hash" }
          collector = SemanticLogger::Metric::Collector.new(aggregator: aggregator)
          with_processor(collector: collector) do
            collector.start

            refute collector.record(:counter, "jobs", 1)
            collector.define_singleton_method(:renew_after_fork) { raise ArgumentError, "renew" }
            collector.instance_variable_set(:@pid, -1)

            refute collector.record(:counter, "jobs", 1)
            refute collector.record(:counter, "users.signup", 1)
          ensure
            collector.instance_variable_set(:@pid, ::Process.pid)
          end
          messages = processor.logger.events.map(&:message)

          assert_equal 2, messages.size
          assert_includes messages.first, 'Failed to record counter "jobs": NoMethodError'
          assert_includes messages.last, 'Failed to record counter "jobs", in the metrics collector: ArgumentError'
          assert_includes messages.last, "This is a defect of Semantic Logger"
        end

        it "reports, apart and as an error, the records of its own metrics dropped for another kind or unit" do
          with_processor do
            collector.start
            2.times do
              collector.record(:counter, "upload.size", 1)
              collector.record(:histogram, "upload.size", 10)
              collector.record(:counter, "semantic_logger.log.processed", 1, internal: true)
              collector.record(:histogram, "semantic_logger.log.processed", 1, internal: true)
              collector.deliver
            end
          end
          events = processor.logger.events

          assert_equal %i[warn error], events.map(&:level)
          assert_includes events.first.message, 'metric "upload.size"'
          assert_includes events.last.message, %(Semantic Logger's own metric "semantic_logger.log.processed")
          assert_includes events.last.message, "This is a defect of Semantic Logger"
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
                SemanticLogger::CoreExt::Process.stub(:daemon?, daemon) do
                  collector.reopen

                  refute_same parent_thread, collector.thread
                  assert_predicate collector.thread, :alive?
                  collector.deliver
                end
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

          it "discards the metrics inherited in a child that was not reopened, as it records" do
            with_processor do
              collector.start
              collector.record(:counter, "inherited", 1)
              parent_thread = collector.thread
              ::Process.stub(:pid, ::Process.pid + 1) do
                collector.record(:counter, "in.child", 1)
                collector.deliver
              ensure
                parent_thread&.kill
              end

              assert_equal ["in.child"], processor.snapshots.pop(timeout: 0).points.map(&:name)
            end
          end

          it "discards them as it delivers too" do
            with_processor do
              collector.start
              collector.record(:counter, "inherited", 1)
              parent_thread = collector.thread
              ::Process.stub(:pid, ::Process.pid + 1) do
                assert collector.deliver
              ensure
                parent_thread&.kill
              end

              assert_empty processor.snapshots.pop(timeout: 0).points
            end
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
