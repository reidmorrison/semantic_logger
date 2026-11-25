require_relative "../test_helper"

class CaptureLogEventsTest < Minitest::Test
  class User
    include SemanticLogger::Loggable

    def enable!
      logger.info("Hello World", metric: "User/enabled")
    end

    def disable!
      logger.info(metric: "User/disabled")
    end

    def fail!
      logger.error("Could not enable")
    end

    def sign_up!
      logger.increment(:"users.signup", dimensions: {plan: "free"})
      logger.time("users.signup.time") { :signed_up }
      logger.record("users.signup.size", 2048, unit: "By")
    end
  end

  describe "SemanticLogger::Test::CaptureLogEvents" do
    let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:user) { User.new }

    it "event" do
      user.stub(:logger, capture_logger) do
        user.enable!
      end

      assert_equal "Hello World", capture_logger.events.last.message
      assert_equal :info, capture_logger.events.last.level
      assert_equal "User/enabled", capture_logger.events.last.metric
      refute_predicate capture_logger.events.last, :metric_only?
    end

    it "captures the backtrace of an event at :error and above, standing in for a logger" do
      user.stub(:logger, capture_logger) do
        user.enable!
        user.fail!
      end

      assert_nil capture_logger.events.first.backtrace
      assert_match(/capture_log_events_test\.rb:\d+:in .*fail!/, capture_logger.events.last.backtrace.first)
    end

    it "captures the backtrace of an event at :error and above, standing in for the processor" do
      SemanticLogger::Logger.stub(:processor, capture_logger) { User.new.fail! }

      assert_match(/capture_log_events_test\.rb:\d+:in .*fail!/, capture_logger.events.last.backtrace.first)
    end

    it "metric only event" do
      user.stub(:logger, capture_logger) do
        user.disable!
      end

      assert_equal :info, capture_logger.events.last.level
      assert_equal "User/disabled", capture_logger.events.last.metric
      assert_predicate capture_logger.events.last, :metric_only?
    end

    it "supports with_level when standing in for a logger" do
      capture_logger.level = :info
      capture_logger.with_level(:warn) do
        capture_logger.info("dropped")
        capture_logger.warn("kept")
      end
      capture_logger.info("after")

      assert_equal %w[kept after], capture_logger.events.map(&:message)
    end

    it "clears the events array when clear is called" do
      capture_logger.info "a message"

      assert_equal(1, capture_logger.events.size)
      capture_logger.clear

      assert_equal(0, capture_logger.events.size)
    end

    it "captures a batch of log events" do
      logs = %w[first second].map do |message|
        log         = SemanticLogger::Log.new("Test", :info)
        log.message = message
        log
      end

      capture_logger.batch(logs)

      assert_equal %w[first second], capture_logger.events.map(&:message)
      assert_equal %i[info info], capture_logger.events.map(&:level)
    end

    describe "metric calls" do
      def assert_captured(metric_events)
        expected = [
          [:counter, "users.signup", nil, {"plan" => "free"}],
          [:histogram, "users.signup.time", "s", nil],
          [:histogram, "users.signup.size", "By", nil]
        ]

        actual = metric_events.map { |metric| [metric.kind, metric.name, metric.unit, metric.dimensions] }

        assert_equal expected, actual
        assert_equal 1, metric_events[0].value
        assert_kind_of Float, metric_events[1].value
        assert_equal 2048, metric_events[2].value
      end

      it "are captured when it stands in for a logger" do
        user.stub(:logger, capture_logger) { user.sign_up! }

        assert_captured capture_logger.metric_events
        assert_empty capture_logger.events
      end

      it "are captured when it stands in for the processor" do
        SemanticLogger::Logger.stub(:processor, capture_logger) { user.sign_up! }

        assert_captured capture_logger.metric_events
      end

      it "capture the name of the logger that made each call as its scope, standing in for the processor" do
        SemanticLogger::Logger.stub(:processor, capture_logger) do
          user.sign_up!
          SemanticLogger["Other"].increment("other")
        end

        scopes = capture_logger.metric_events.map(&:scope)

        assert_equal %w[CaptureLogEventsTest::User CaptureLogEventsTest::User CaptureLogEventsTest::User Other], scopes
      end

      it "capture a scope as it is recorded: a frozen String, from a Symbol too" do
        logger      = SemanticLogger["Orders"]
        logger.name = :orders
        given       = +"Payments"
        SemanticLogger::Logger.stub(:processor, capture_logger) do
          logger.increment("orders.placed")
          SemanticLogger[given].increment("payments.made")
        end
        given << "!"

        assert_equal %w[orders Payments], capture_logger.metric_events.map(&:scope)
        assert capture_logger.metric_events.map(&:scope).all?(&:frozen?)
      end

      it "capture no scope for a logger without a name" do
        SemanticLogger::Logger.stub(:processor, capture_logger) { SemanticLogger[Class.new].increment("a") }

        assert_nil capture_logger.metric_events.first.scope
      end

      it "capture no scope standing in for a logger, which is not told which logger made the call" do
        user.stub(:logger, capture_logger) { user.sign_up! }

        assert_equal [nil] * 3, capture_logger.metric_events.map(&:scope)
      end

      it "are captured without a metric appender, and whatever the level" do
        capture_logger.level = :fatal
        capture_logger.increment("users.signup")

        assert_equal ["users.signup"], capture_logger.metric_events.map(&:name)
      end

      it "are frozen, with the dimensions as they are recorded" do
        dimensions = {plan: "free", tier: :gold}
        capture_logger.increment("users.signup", dimensions: dimensions)
        metric = capture_logger.metric_events.first
        dimensions[:plan] = "paid"

        assert_predicate metric, :frozen?
        assert_predicate metric.dimensions, :frozen?
        assert_equal({"plan" => "free", "tier" => "gold"}, metric.dimensions)
        assert metric.matches?(dimensions: {plan: "free", tier: :gold})
        assert metric.matches?(dimensions: {"plan" => "free", "tier" => "gold"})
        refute metric.matches?(dimensions: {plan: "paid", tier: :gold})
      end

      it "has the name frozen, and no dimensions for an empty Hash, as they are recorded" do
        capture_logger.increment(+"users.signup", dimensions: {})
        metric = capture_logger.metric_events.first

        assert_predicate metric.name, :frozen?
        assert_nil metric.dimensions
        assert metric.matches?(dimensions: {})
        assert metric.matches?(dimensions: :nil)
        with_plan = SemanticLogger::Test::MetricEvent.new(kind: :counter, name: "a", value: 1,
                                                          dimensions: {plan: "free"})

        refute with_plan.matches?(dimensions: {})
      end

      it "does not capture Semantic Logger's own metrics" do
        refute capture_logger.record_metric(:counter, "semantic_logger.log.processed", 1, internal: true)
        assert_empty capture_logger.metric_events
      end

      it "drops, without raising, a metric that fails as it is captured" do
        # Dimensions that raise as they are read, so that capturing them raises.
        dimensions = Class.new(Hash) { def each_pair(*) = raise(NoMethodError, "each_pair") }[plan: "free"]
        warnings   = []
        capture_logger.logger.stub(:warn, ->(message) { warnings << message }) do
          SemanticLogger::Logger.stub(:processor, capture_logger) do
            refute capture_logger.increment("users.signup", dimensions: dimensions)
          end
        end

        assert_empty capture_logger.metric_events
        assert_includes warnings.first, 'Failed to record counter "users.signup"'
      end

      it "drops the ones that would not be recorded, warning once" do
        warnings = []
        capture_logger.logger.stub(:warn, ->(message) { warnings << message }) do
          SemanticLogger::Logger.stub(:processor, capture_logger) do
            refute capture_logger.increment("users.signup", -1)
            refute capture_logger.increment("users.signup", -1)
            refute capture_logger.record("order.total", Float::NAN)
          end
        end

        assert_empty capture_logger.metric_events
        assert_equal 2, warnings.size
      end

      it "are cleared with the events" do
        capture_logger.info("a message")
        capture_logger.increment("users.signup")
        capture_logger.clear

        assert_empty capture_logger.events
        assert_empty capture_logger.metric_events
      end
    end

    describe "on_log subscribers" do
      let(:calls) { [] }

      before do
        SemanticLogger.on_log { |log| calls << log.message }
      end

      after do
        SemanticLogger::Logger.clear_subscribers
      end

      it "are called once when it stands in for a logger" do
        user.stub(:logger, capture_logger) do
          user.enable!
        end

        assert_equal 1, calls.count("Hello World")
        assert_equal(1, capture_logger.events.count { |log| log.message == "Hello World" })
      end

      it "are called once for tagged and measured events when it stands in for a logger" do
        capture_logger.tagged("tag") { capture_logger.info("tagged") }
        capture_logger.measure_info("measured") { nil }

        assert_equal %w[tagged measured], calls
        assert_equal %w[tagged measured], capture_logger.events.map(&:message)
      end

      it "are called once by semantic_logger_events without a class" do
        events = semantic_logger_events { user.enable! }

        assert_equal 1, calls.count("Hello World")
        assert_equal(1, events.count { |log| log.message == "Hello World" })
      end

      it "are called once when it stands in for the processor" do
        SemanticLogger::Logger.stub(:processor, capture_logger) do
          user.enable!
        end

        assert_equal 1, calls.count("Hello World")
        assert_equal(1, capture_logger.events.count { |log| log.message == "Hello World" })
      end

      it "are called once when it is added as an appender" do
        appender = SemanticLogger.add_appender(appender: capture_logger)
        begin
          user.enable!
          SemanticLogger.flush
        ensure
          SemanticLogger.remove_appender(appender)
        end

        assert_equal 1, calls.count("Hello World")
        assert_equal(1, capture_logger.events.count { |log| log.message == "Hello World" })
      end
    end
  end
end
