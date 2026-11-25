require_relative "../test_helper"

# Tests for the SemanticLogger::Test::Minitest helpers themselves:
# semantic_logger_events (capture) and assert_semantic_logger_event (assertion).
class MinitestHelpersTest < Minitest::Test
  class User
    include SemanticLogger::Loggable

    def enable!
      logger.info("User enabled", first_name: "Jack", last_name: "Jones", metric: "User/enabled")
    end

    def disable!
      logger.info(metric: "User/disabled")
    end

    def fail!
      logger.error("Boom", StandardError.new("kaboom"))
    end
  end

  describe "semantic_logger_events" do
    it "captures every event by default" do
      events = semantic_logger_events { User.new.enable! }

      assert_equal ["User enabled"], events.map(&:message)
    end

    it "lets the code under test flush" do
      events = semantic_logger_events do
        User.new.enable!
        SemanticLogger.flush
      end

      assert_equal ["User enabled"], events.map(&:message)
    end

    it "captures only the supplied class's events" do
      events = semantic_logger_events(klass: User) { User.new.enable! }

      assert_equal 1, events.size
      assert_equal "User enabled", events.first.message
    end

    it "takes the class only as klass:" do
      assert_raises(ArgumentError) { semantic_logger_events(User) { User.new.enable! } }
    end

    it "captures events below the global default level" do
      original_level = SemanticLogger.default_level
      SemanticLogger.default_level = :error
      begin
        events = semantic_logger_events { User.new.enable! }

        assert_equal :info, events.first.level
      ensure
        SemanticLogger.default_level = original_level
      end
    end
  end

  describe "assert_semantic_logger_event" do
    let(:event) { semantic_logger_events { User.new.enable! }.first }
    let(:error_event) { semantic_logger_events { User.new.fail! }.first }

    it "matches on level and exact message" do
      assert_semantic_logger_event(event, level: :info, message: "User enabled")
    end

    it "matches a partial message" do
      assert_semantic_logger_event(event, message_includes: "enabled")
    end

    it "matches an exact payload" do
      assert_semantic_logger_event(event, payload: {first_name: "Jack", last_name: "Jones"})
    end

    it "matches a partial payload" do
      assert_semantic_logger_event(event, payload_includes: {first_name: "Jack"})
    end

    it "matches a metric" do
      assert_semantic_logger_event(event, metric: "User/enabled")
    end

    it "matches a Class expectation against the value's type" do
      assert_semantic_logger_event(event, time: Time)
    end

    it "matches a :nil expectation against a nil value" do
      assert_semantic_logger_event(event, exception: :nil)
    end

    it "matches partial exception attributes" do
      assert_semantic_logger_event(error_event, level: :error, exception_includes: {message: "kaboom"})
    end

    it "matches the exception class" do
      assert_semantic_logger_event(error_event, exception: StandardError)
    end

    it "matches the call site" do
      original = SemanticLogger.call_site_level
      SemanticLogger.call_site_level = :info
      begin
        event = semantic_logger_events { User.new.enable! }.first
      ensure
        SemanticLogger.call_site_level = original
      end

      expected = SemanticLogger::CallSite.new(path: __FILE__, line: 10, label: event.call_site.label)

      assert_semantic_logger_event(event, call_site: SemanticLogger::CallSite)
      assert_semantic_logger_event(event, call_site: expected)
    end

    it "fails when there is no event" do
      assert_raises(Minitest::Assertion) do
        assert_semantic_logger_event(nil, message: "anything")
      end
    end

    it "fails when an attribute differs" do
      assert_raises(Minitest::Assertion) do
        assert_semantic_logger_event(event, level: :error)
      end
    end

    it "fails when a partial message is absent" do
      assert_raises(Minitest::Assertion) do
        assert_semantic_logger_event(event, message_includes: "disabled")
      end
    end
  end

  class Signup
    include SemanticLogger::Loggable

    def call(plan)
      logger.increment("users.signup", dimensions: {plan: plan})
      logger.time("users.signup.time") { logger.info("Signed up") }
      logger.record("users.signup.size", 2048, unit: "By")
    end
  end

  describe "semantic_logger_metrics" do
    it "captures every metric call, and returns them" do
      metrics = semantic_logger_metrics { Signup.new.call("free") }

      assert_equal %w[users.signup users.signup.time users.signup.size], metrics.map(&:name)
      assert_equal %i[counter histogram histogram], metrics.map(&:kind)
    end

    it "captures only the supplied class's metric calls" do
      metrics = semantic_logger_metrics(klass: Signup) do
        Signup.new.call("free")
        SemanticLogger["Other"].increment("other")
      end

      assert_equal %w[users.signup users.signup.time users.signup.size], metrics.map(&:name)
    end

    it "keeps semantic_logger_events returning the log events only" do
      events = semantic_logger_events { Signup.new.call("free") }

      assert_equal ["Signed up"], events.map(&:message)
    end
  end

  describe "assert_metric" do
    let(:metrics) { semantic_logger_metrics { Signup.new.call("free") } }

    it "returns the matching metric" do
      metric = assert_metric(metrics, name: "users.signup", kind: :counter, value: 1, dimensions: {plan: "free"})

      assert_equal "users.signup", metric.name
    end

    it "matches a Symbol name, a Class, a Range, a Regexp, and :nil" do
      assert_metric(metrics, name: :"users.signup.time", kind: :histogram, value: Float, unit: "s")
      assert_metric(metrics, name: /\.size\z/, value: 1024..4096, unit: "By", dimensions: :nil)
    end

    it "accepts a single metric" do
      assert_metric(metrics.first, name: "users.signup")
    end

    it "fails, listing the metrics captured, when none matches" do
      error = assert_raises(Minitest::Assertion) do
        assert_metric(metrics, name: "users.signup", value: 2)
      end

      assert_includes error.message, "No metric matching #{{name: 'users.signup', value: 2}.inspect} was captured"
      assert_includes error.message, "Captured 3 metric(s)"
      assert_includes error.message, "users.signup.size"
    end

    it "fails when nothing was captured" do
      assert_raises(Minitest::Assertion) { assert_metric([], name: "users.signup") }
    end

    it "matches name: :nil only when the name is nil" do
      refute metrics.first.matches?(name: :nil)
      assert SemanticLogger::Test::MetricEvent.new(kind: :counter, name: nil, value: 1).matches?(name: :nil)
    end

    it "matches dimensions given with Symbol or String keys, and Symbol values" do
      assert_metric(metrics, name: "users.signup", dimensions: {"plan" => "free"})
      assert_metric(metrics, name: "users.signup", dimensions: {plan: :free})
    end

    it "raises ArgumentError for an attribute that a metric does not have" do
      assert_raises(ArgumentError) { metrics.first.matches?(level: :info) }
    end

    it "matches the scope, the name of the logger that made the call" do
      metric = assert_metric(metrics, name: "users.signup", scope: "MinitestHelpersTest::Signup")

      assert_equal "MinitestHelpersTest::Signup", metric.scope
      assert_metric(metrics, name: "users.signup", scope: /Signup\z/)
      assert_metric(metrics, name: "users.signup", scope: :"MinitestHelpersTest::Signup")
      assert_raises(Minitest::Assertion) { assert_metric(metrics, name: "users.signup", scope: "Other") }
      assert_raises(Minitest::Assertion) { assert_metric(metrics, name: "users.signup", scope: :nil) }
    end

    it "matches scope: :nil for the metric calls captured with klass:, which have no scope" do
      captured = semantic_logger_metrics(klass: Signup) { Signup.new.call("free") }

      assert_metric(captured, name: "users.signup", scope: :nil)
    end
  end
end
