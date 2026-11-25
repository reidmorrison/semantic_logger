require_relative "../test_helper"

module Metric
  # The metric: of log and measure_* calls is recorded at every level, and whether or not min_duration
  # is met, once a metric appender is present. Without one, they behave as in 5.x.
  class LevelIndependentTest < Minitest::Test
    describe "metric: on log calls" do
      let(:logger) do
        logger       = SemanticLogger["Metric::LevelIndependentTest"]
        logger.level = :info
        logger
      end
      let(:metric_appender) { InMemoryMetricAppender.new }
      # Receives the log entries, metric-only ones included (metrics: true).
      let(:log_appender) { SemanticLogger::Test::CaptureLogEvents.new }

      before do
        SemanticLogger.add_appender(appender: log_appender)
      end

      after do
        SemanticLogger.remove_appender(log_appender)
        SemanticLogger.appenders.dup.each do |added|
          SemanticLogger.remove_appender(added) if added.metrics_interval
        end
      end

      # Returns [Array<SemanticLogger::Log>] the log entries of this logger written once flushed (the
      # test reporter logs too).
      def logs
        SemanticLogger.flush
        log_appender.events.select { |log| log.name == logger.name }
      end

      # Returns [Array<SemanticLogger::Metric::Snapshot::Point>] the points written once flushed, but
      # those of the test reporter.
      def points
        SemanticLogger.flush
        metric_appender.points.reject { |point| point.name.start_with?("minitest/") }
      end

      # Returns [Array<String>] the warnings that the block made on the internal logger.
      def warnings_of(&)
        warnings = []
        SemanticLogger::Logger.processor.logger.stub(:warn, ->(message) { warnings << message }, &)
        warnings
      end

      describe "with a metric appender" do
        before do
          SemanticLogger.add_appender(metric: metric_appender)
        end

        it "records the metric of a log call whose level passes, and logs it" do
          assert logger.info("Signed up", metric: "users.signup", dimensions: {plan: "free"})
          point = points.first

          assert_equal ["Signed up"], logs.map(&:message)
          assert_equal "users.signup", logs.first.metric
          assert_equal :counter, point.kind
          assert_equal "users.signup", point.name
          assert_equal 1, point.value
          assert_equal({"plan" => "free"}, point.dimensions)
        end

        it "records the metric of a log call below the level, which logs nothing" do
          refute logger.debug("Signed up", metric: "users.signup", metric_amount: 3, dimensions: {plan: "free"})
          refute logger.trace(metric: "users.signup", dimensions: {plan: "free"})
          point = points.first

          assert_empty logs
          assert_equal 1, points.size
          assert_equal 4, point.value
          assert_equal({"plan" => "free"}, point.dimensions)
        end

        it "records a duration given below the level as a histogram in seconds" do
          logger.debug("Queued", metric: "queue.latency", duration: 1500)
          point = points.first

          assert_equal :histogram, point.kind
          assert_equal "s", point.unit
          assert_in_delta 1.5, point.value.sum
        end

        it "records the metric of a log call when min_duration is not met" do
          logger.info("Slow call", metric: "supplier.call", duration: 5, min_duration: 100)
          logger.debug("Slow call", metric: "supplier.call", duration: 5, min_duration: 100)

          assert_empty logs
          assert_equal 2, points.first.value.count
        end

        it "records a metric-only call, still logging it to the appenders with metrics: true" do
          logger.info(metric: "users.signup")

          assert_equal ["users.signup"], logs.map(&:metric)
          assert_nil logs.first.message
          assert_equal ["users.signup"], points.map(&:name)
        end

        it "records the metric that a logging block returns, when the level passes" do
          logger.info("Signed up") { {metric: "users.signup", metric_amount: 2} }
          # Below the level the block is not called.
          logger.debug("Signed up") { {metric: "users.signup", metric_amount: 5} }

          assert_equal [2], points.map(&:value)
        end

        it "records the metric of a log call that a filter rejects" do
          logger.filter = ->(_log) { false }
          logger.info("Signed up", metric: "users.signup")

          assert_empty logs
          assert_equal ["users.signup"], points.map(&:name)
        end

        it "reads only a Hash given as the arguments of the log call" do
          logger.debug("Signed up", {metric: "users.signup"}, RuntimeError.new("boom"))
          logger.debug(nil, {metric: "users.signup"})
          logger.debug("Signed up", "metric: users.signup")
          # A metric argument with a value that is not valid for it is ignored, as when logged.
          logger.debug("Signed up", metric: "users.signup", metric_amount: "3", dimensions: "plan")
          point = points.first

          assert_equal 1, points.size
          assert_equal 1, point.value
          assert_equal({}, point.dimensions)
        end

        it "reads a Hash subclass below the level by Hash#key?, never by its own #key?" do
          subclass  = Class.new(Hash) { def key?(*) = raise("key?") }
          arguments = subclass[metric: "users.signup"]

          refute logger.debug("Signed up", arguments)
          refute logger.add(:debug, arguments)
          refute logger.debug("Signed up", subclass["metric" => "users.signup"])

          assert_equal [2], points.map(&:value)
        end

        it "drops a negative metric_amount with one warning, and still logs the entry" do
          warnings = warnings_of do
            logger.info("Item removed", metric: "level_independent.negative", metric_amount: -1)
            logger.debug("Item removed", metric: "level_independent.negative", metric_amount: -1)
            logger.info(metric: "level_independent.negative", metric_amount: -2)
          end

          assert_empty points
          assert_equal([-1, -2], logs.map(&:metric_amount))
          assert_equal(["level_independent.negative"] * 2, logs.map(&:metric))
          assert_equal 1, warnings.size
          assert_includes warnings.first, 'Dropped counter "level_independent.negative"'
        end

        it "records the metric of Logger#add below the level, as the level methods do" do
          refute logger.add(:debug, "Signed up", {metric: "users.signup", metric_amount: 2})
          refute logger.add(:debug, {metric: "users.signup"})
          refute logger.add(:debug, "Signed up", "users.signup")

          assert_empty logs
          assert_equal [3], points.map(&:value)
        end

        it "records nothing, and never raises, when the processor is a stand-in without metric methods" do
          stand_in = Object.new
          stand_in.define_singleton_method(:log) { |_log| true }

          SemanticLogger::Logger.stub(:processor, stand_in) do
            assert logger.info("Signed up", metric: "users.signup")
            refute logger.debug("Signed up", metric: "users.signup")
            assert_equal :added, logger.measure_debug("Called supplier", metric: "supplier.call") { :added }
          end

          assert_empty points
        end

        it "records the metric of #backtrace below the level" do
          logger.backtrace(level: :debug, metric: "backtraces", metric_amount: 2)
          logger.backtrace(level: :info, metric: "backtraces")

          assert_equal 1, logs.size
          assert_equal [3], points.map(&:value)
        end

        it "answers whether metrics are collected, publicly, so that a caller can skip building dimensions" do
          assert_predicate logger, :collecting_metrics?
          SemanticLogger::Logger.stub(:processor, Object.new) do
            refute_predicate logger, :collecting_metrics?
          end
          assert_respond_to logger, :collecting_metrics?
          refute_respond_to InMemoryAppender.new, :collecting_metrics?
        end

        it "collects nothing, and never recurses, when an appender stands in for the processor" do
          SemanticLogger::Logger.stub(:processor, InMemoryAppender.new) do
            assert logger.info("Signed up", metric: "users.signup")
            refute_predicate logger, :collecting_metrics?
          end
        end

        describe "measure" do
          it "records the time of the block when the level passes, and logs it" do
            result = logger.measure_info("Called supplier", metric: "supplier.call") { :added }
            point  = points.first

            assert_equal :added, result
            assert_equal ["Called supplier"], logs.map(&:message)
            assert_equal :histogram, point.kind
            assert_equal "s", point.unit
            assert_in_delta logs.first.duration / 1000.0, point.value.sum
          end

          it "times the block below the level, logging nothing, and returns its result" do
            result = logger.measure_debug("Called supplier", metric: "supplier.call", dimensions: {name: "acme"}) do
              sleep 0.01
              :added
            end
            point = points.first

            assert_equal :added, result
            assert_empty logs
            assert_equal :histogram, point.kind
            assert_equal "s", point.unit
            assert_equal({"name" => "acme"}, point.dimensions)
            assert_operator point.value.min, :>=, 0.01
            assert_operator point.value.max, :<, 1
          end

          it "records the time below the level when the block raises, and raises again" do
            assert_raises(ArgumentError) do
              logger.measure_debug("Called supplier", metric: "supplier.call") { raise ArgumentError, "boom" }
            end

            assert_empty logs
            assert_equal 1, points.first.value.count
            assert_equal({"error.type" => "ArgumentError"}, points.first.dimensions)
          end

          it "adds error.type to the metric, not the log entry, when the block raises at the level" do
            assert_raises(ArgumentError) do
              logger.measure_info("Called supplier", metric: "supplier.call", dimensions: {name: "acme"}) do
                raise ArgumentError, "boom"
              end
            end
            logger.measure_info("Called supplier", metric: "supplier.call", dimensions: {name: "acme"}) { :ok }

            assert_equal [{name: "acme"}] * 2, logs.map(&:dimensions)
            assert_equal [{"name" => "acme", "error.type" => "ArgumentError"}, {"name" => "acme"}],
                         points.map(&:dimensions)
          end

          it "names an anonymous exception class after its nearest named ancestor" do
            2.times do
              assert_raises(ArgumentError) do
                logger.measure_info("Called", metric: "a") { raise Class.new(ArgumentError), "boom" }
              end
            end

            assert_equal [{"error.type" => "ArgumentError"}], points.map(&:dimensions)
          end

          it "names a class with a constant name that is not ASCII after itself" do
            unless LevelIndependentTest.const_defined?(:Ärger)
              LevelIndependentTest.const_set(:Ärger,
                                             Class.new(ArgumentError))
            end
            assert_raises(ArgumentError) do
              logger.measure_info("Called", metric: "a") { raise LevelIndependentTest.const_get(:Ärger) }
            end

            assert_equal "Metric::LevelIndependentTest::Ärger", points.first.dimensions["error.type"]
          end

          it "never calls a name that the exception class defines, and skips a temporary name" do
            raising_name = Class.new(ArgumentError) { def self.name = raise("its name raised") }
            assert_raises(raising_name) { logger.measure_info("Called", metric: "a") { raise raising_name } }
            if Module.method_defined?(:set_temporary_name)
              temporary = Class.new(ArgumentError).tap { |klass| klass.set_temporary_name("error<1>") }
              assert_raises(temporary) { logger.measure_info("Called", metric: "a") { raise temporary } }
            end

            assert_equal [{"error.type" => "ArgumentError"}], points.map(&:dimensions)
          end

          it "keeps an error.type given, and adds none for an exception given rather than raised" do
            assert_raises(ArgumentError) do
              logger.measure_info("Called", metric: "a", dimensions: {"error.type" => "timeout"}) do
                raise ArgumentError
              end
            end
            assert_raises(ArgumentError) do
              logger.measure_info("Called", metric: "b", duration: 5, exception: ArgumentError.new("given"))
            end

            assert_equal [{"error.type" => "timeout"}, {}], points.map(&:dimensions)
          end

          it "records the time below the level when the block breaks out early" do
            result = logger.measure_debug("Called supplier", metric: "supplier.call") { break :early }

            assert_equal :early, result
            assert_equal 1, points.first.value.count
          end

          it "records a duration given without a block below the level" do
            assert_nil logger.measure_debug("Called supplier", metric: "supplier.call", duration: 250)
            assert_nil logger.measure_debug("Called supplier", metric: "supplier.call")

            assert_in_delta 0.25, points.first.value.sum
          end

          it "accepts all the options as a Hash in place of the message" do
            logger.measure_debug(message: "Called supplier", metric: "supplier.call", duration: 250)
            logger.measure(:debug, message: "Called supplier", metric: "supplier.call", duration: 250)
            logger.measure_debug({message: "Called supplier", metric: "supplier.call", duration: 250}, {})

            assert_equal 3, points.first.value.count
          end

          it "reads the options once the block has returned, as when the level passes" do
            logger.measure_debug("Called supplier", metric: "supplier.call") do |params|
              params[:dimensions] = {name: "acme"}
            end

            assert_equal [{"name" => "acme"}], points.map(&:dimensions)
          end

          it "records the time when min_duration is not met" do
            logger.measure_info("Called supplier", metric: "supplier.call", min_duration: 60_000) { :added }

            assert_empty logs
            assert_equal 1, points.first.value.count
          end

          it "records nothing below the level when the block adds the metric to the options" do
            result = logger.measure_debug("Called supplier", {user: "jack"}) do |params|
              params[:metric] = "supplier.call"
              :added
            end

            assert_equal :added, result
            assert_empty points
          end

          it "yields the params, and records nothing, without a metric" do
            yielded = logger.measure_debug("Called supplier", {user: "jack"}) { |params| params }

            assert_equal({user: "jack"}, yielded)
            assert_empty points
          end
        end
      end

      describe "without a metric appender" do
        it "logs as before, and records nothing" do
          assert logger.info("Signed up", metric: "users.signup")
          refute logger.debug("Signed up", metric: "users.signup")
          # As in 5.x, a call whose level passes returns true, even when min_duration is not met.
          assert logger.info("Slow call", metric: "supplier.call", duration: 5, min_duration: 100)

          assert_equal ["Signed up"], logs.map(&:message)
          refute_predicate SemanticLogger::Metric.collector, :collecting?
        end

        it "returns the result of a measure block below the level, yielding its params" do
          params = {metric: "supplier.call"}
          result = logger.measure_debug("Called supplier", params) { |yielded| yielded }

          assert_same params, result
          assert_nil logger.measure_debug("Called supplier", metric: "supplier.call")
          assert_empty logs
        end

        it "logs a negative metric_amount without a warning" do
          warnings = warnings_of { logger.info(metric: "level_independent.unrecorded", metric_amount: -1) }

          assert_equal([-1], logs.map(&:metric_amount))
          assert_empty warnings
        end
      end
    end

    describe "SemanticLogger::Test::CaptureLogEvents" do
      let(:logger) do
        logger       = SemanticLogger["Metric::LevelIndependentTest"]
        logger.level = :info
        logger
      end

      it "captures the metric of log calls at every level, standing in for the processor" do
        metrics = semantic_logger_metrics do
          logger.info("Signed up", metric: "users.signup", dimensions: {plan: "free"})
          logger.debug("Signed up", metric: "users.signup", metric_amount: 2)
          logger.measure_debug("Called supplier", metric: "supplier.call") { :added }
          logger.info("Slow call", metric: "supplier.slow", duration: 5, min_duration: 100)
        end

        assert_metric(metrics, name: "users.signup", kind: :counter, value: 1, dimensions: {plan: "free"})
        assert_metric(metrics, name: "users.signup", kind: :counter, value: 2)
        assert_metric(metrics, name: "supplier.call", kind: :histogram, unit: "s", value: Float)
        assert_metric(metrics, name: "supplier.slow", kind: :histogram, unit: "s", value: 0.005)
        assert_equal 4, metrics.size
      end

      it "captures the metric of log calls, and the entries, standing in for a logger" do
        capture       = SemanticLogger::Test::CaptureLogEvents.new
        capture.level = :info
        capture.info("Signed up", metric: "users.signup")
        capture.debug("Signed up", metric: "users.signup")

        assert_equal ["Signed up"], capture.events.map(&:message)
        assert_equal ["users.signup"] * 2, capture.metric_events.map(&:name)
      end
    end
  end
end
