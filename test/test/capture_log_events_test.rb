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
      refute capture_logger.events.last.metric_only?
    end

    it "metric only event" do
      user.stub(:logger, capture_logger) do
        user.disable!
      end
      assert_equal :info, capture_logger.events.last.level
      assert_equal "User/disabled", capture_logger.events.last.metric
      assert capture_logger.events.last.metric_only?
    end

    it "clears the events array when clear is called" do
      capture_logger.info "a message"
      assert_equal(1, capture_logger.events.size)
      capture_logger.clear
      assert_equal(0, capture_logger.events.size)
    end
  end
end
