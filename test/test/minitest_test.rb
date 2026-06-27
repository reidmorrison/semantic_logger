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

    it "captures only the supplied class's events" do
      events = semantic_logger_events(User) { User.new.enable! }

      assert_equal 1, events.size
      assert_equal "User enabled", events.first.message
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
end
