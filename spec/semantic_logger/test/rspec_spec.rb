require_relative "../../spec_helper"

# Sample application class that emits log events.
class RSpecMatcherUser
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

# Sample application class that makes metric calls.
class RSpecMatcherSignup
  include SemanticLogger::Loggable

  def call(plan)
    logger.increment("users.signup", dimensions: {plan: plan})
    logger.time("users.signup.time") { :signed_up }
    logger.record("users.signup.size", 2048, unit: "By")
  end
end

RSpec.describe SemanticLogger::Test::RSpec do
  let(:user) { RSpecMatcherUser.new }

  describe "#capture_semantic_logger_events" do
    it "captures every event by default" do
      events = capture_semantic_logger_events { user.enable! }

      expect(events.map(&:message)).to eq(["User enabled"])
    end

    it "captures only the supplied class's events" do
      events = capture_semantic_logger_events(RSpecMatcherUser) { user.enable! }

      expect(events.size).to eq(1)
      expect(events.first.message).to eq("User enabled")
    end

    it "captures events below the global default level" do
      SemanticLogger.default_level = :error

      events = capture_semantic_logger_events { user.enable! }

      expect(events.first.level).to eq(:info)
    ensure
      SemanticLogger.default_level = :trace
    end

    it "restores the original processor afterwards" do
      capture_semantic_logger_events { user.enable! }

      expect(SemanticLogger::Logger.processor).not_to be_a(SemanticLogger::Test::CaptureLogEvents)
    end
  end

  describe "be_a_semantic_logger_event" do
    let(:event) { capture_semantic_logger_events { user.enable! }.first }

    it "matches on level and exact message" do
      expect(event).to be_a_semantic_logger_event(level: :info, message: "User enabled")
    end

    it "matches a partial message" do
      expect(event).to be_a_semantic_logger_event(message_includes: "enabled")
    end

    it "matches an exact payload" do
      expect(event).to be_a_semantic_logger_event(
        payload: {first_name: "Jack", last_name: "Jones"}
      )
    end

    it "matches a partial payload" do
      expect(event).to be_a_semantic_logger_event(payload_includes: {first_name: "Jack"})
    end

    it "matches a metric" do
      expect(event).to be_a_semantic_logger_event(metric: "User/enabled")
    end

    it "matches the call site" do
      SemanticLogger.call_site_level = :info
      event = capture_semantic_logger_events { user.enable! }.first

      expect(event).to be_a_semantic_logger_event(call_site: SemanticLogger::CallSite)
    ensure
      SemanticLogger.call_site_level = nil
    end

    it "matches a Class expectation against the value's type" do
      expect(event).to be_a_semantic_logger_event(time: Time)
    end

    it "matches a :nil expectation against a nil value" do
      expect(event).to be_a_semantic_logger_event(exception: :nil)
    end

    it "does not match when an attribute differs" do
      expect(event).not_to be_a_semantic_logger_event(level: :error)
    end

    it "does not match when a partial message is absent" do
      expect(event).not_to be_a_semantic_logger_event(message_includes: "disabled")
    end

    it "raises when given an unknown attribute" do
      expect { be_a_semantic_logger_event(bogus: 1) }.to raise_error(ArgumentError, /bogus/)
    end

    it "produces a helpful failure message" do
      matcher = be_a_semantic_logger_event(level: :error)
      matcher.matches?(event)

      expect(matcher.failure_message).to include("level was :info")
    end

    context "with an exception" do
      let(:event) { capture_semantic_logger_events { user.fail! }.first }

      it "matches partial exception attributes" do
        expect(event).to be_a_semantic_logger_event(
          level:              :error,
          exception_includes: {message: "kaboom"}
        )
      end

      it "matches the exception class" do
        expect(event).to be_a_semantic_logger_event(exception: StandardError)
      end
    end
  end

  describe "a_semantic_logger_event" do
    it "composes inside other matchers" do
      events = capture_semantic_logger_events { user.enable! }

      expect(events).to include(a_semantic_logger_event(message: "User enabled"))
    end
  end

  describe "log_semantic_logger_event" do
    it "matches when the block logs a matching event" do
      expect { user.enable! }.to(
        log_semantic_logger_event(level: :info, message: "User enabled")
      )
    end

    it "scopes capture to a class with on:" do
      expect { user.enable! }.to(
        log_semantic_logger_event(on: RSpecMatcherUser, metric: "User/enabled")
      )
    end

    it "does not match when no event matches" do
      expect { user.enable! }.not_to(
        log_semantic_logger_event(message: "Something else")
      )
    end

    it "matches a metric only event" do
      expect { user.disable! }.to(
        log_semantic_logger_event(metric: "User/disabled")
      )
    end

    it "describes its expectations once" do
      matcher = log_semantic_logger_event(level: :info)

      expect(matcher.description).to eq("log a semantic logger event matching #{{level: :info}.inspect}")
    end
  end

  describe "#capture_semantic_logger_metrics" do
    let(:signup) { RSpecMatcherSignup.new }

    it "captures every metric call" do
      metrics = capture_semantic_logger_metrics { signup.call("free") }

      expect(metrics.map(&:name)).to eq(%w[users.signup users.signup.time users.signup.size])
    end

    it "captures only the supplied class's metric calls" do
      metrics = capture_semantic_logger_metrics(RSpecMatcherSignup) do
        signup.call("free")
        SemanticLogger["Other"].increment("other")
      end

      expect(metrics.map(&:name)).to eq(%w[users.signup users.signup.time users.signup.size])
    end

    it "restores the original processor afterwards" do
      capture_semantic_logger_metrics { signup.call("free") }

      expect(SemanticLogger::Logger.processor).not_to be_a(SemanticLogger::Test::CaptureLogEvents)
    end
  end

  describe "be_a_semantic_logger_metric" do
    let(:metrics) { capture_semantic_logger_metrics { RSpecMatcherSignup.new.call("free") } }

    it "matches a metric call" do
      expect(metrics.first).to be_a_semantic_logger_metric(
        name: "users.signup", kind: :counter, value: 1, dimensions: {plan: "free"}
      )
    end

    it "matches a Class, a Range, a Regexp, and :nil" do
      expect(metrics[1]).to be_a_semantic_logger_metric(name: /time/, kind: :histogram, value: Float, unit: "s")
      expect(metrics[2]).to be_a_semantic_logger_metric(value: 1024..4096, dimensions: :nil)
    end

    it "does not match when an attribute differs" do
      expect(metrics.first).not_to be_a_semantic_logger_metric(name: "users.signup", value: 2)
    end

    it "explains a mismatch" do
      matcher = be_a_semantic_logger_metric(value: 2)

      expect(matcher.matches?(metrics.first)).to be(false)
      expect(matcher.failure_message).to include("users.signup")
    end

    it "rejects an unknown attribute" do
      expect { be_a_semantic_logger_metric(level: :info) }.to raise_error(ArgumentError, /level/)
    end
  end

  describe "a_semantic_logger_metric" do
    it "composes inside other matchers" do
      metrics = capture_semantic_logger_metrics { RSpecMatcherSignup.new.call("free") }

      expect(metrics).to include(a_semantic_logger_metric(name: "users.signup", kind: :counter, value: 1))
    end
  end

  describe "record_semantic_logger_metric" do
    let(:signup) { RSpecMatcherSignup.new }

    it "matches when the block makes a matching metric call" do
      expect { signup.call("free") }.to record_semantic_logger_metric(name: "users.signup", value: 1)
    end

    it "scopes capture to a class with on:" do
      expect { signup.call("free") }.to(
        record_semantic_logger_metric(on: RSpecMatcherSignup, name: "users.signup.size", unit: "By")
      )
    end

    it "does not match when no metric call matches" do
      expect { signup.call("free") }.not_to record_semantic_logger_metric(name: "users.left")
    end

    it "lists the metric calls captured when it fails" do
      matcher = record_semantic_logger_metric(name: "users.left")

      expect(matcher.matches?(-> { signup.call("free") })).to be(false)
      expect(matcher.failure_message).to include("Captured 3 metric(s)")
    end

    it "describes its expectations once" do
      matcher = record_semantic_logger_metric(name: "users.left")

      expect(matcher.description).to eq("record a semantic logger metric matching #{{name: 'users.left'}.inspect}")
    end
  end
end
