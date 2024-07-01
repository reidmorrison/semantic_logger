require_relative "test_helper"

class DebugAsTraceLoggerTest < Minitest::Test
  # Keep log calls in memory
  class LogTester < SemanticLogger::DebugAsTraceLogger
    attr_accessor :events

    def log(log)
      (@events ||= []) << log
    end
  end

  describe SemanticLogger::Logger do
    let(:logger) { LogTester.new("TestLogger") }
    let(:payload) { {session_id: "HSSKLEU@JDK767", tracking_number: 12_345, message: "Message from payload"} }

    describe ".level?" do
      it "return false for debug? with instance :debug level" do
        logger.level = :debug
        assert_equal :debug, logger.level, logger.inspect
        refute logger.debug?, logger.inspect
        refute logger.trace?, logger.inspect
      end

      it "return true for debug? with instance :info level" do
        logger.level = :info
        assert_equal :info, logger.level, logger.inspect
        refute logger.debug?, logger.inspect
        refute logger.trace?, logger.inspect
      end
    end

    describe "log" do
      it "not log trace when level is debug" do
        logger.level = :debug
        logger.trace("hello world", payload) { "Calculations" }
        refute logger.events
      end

      it "not log debug when level is debug" do
        logger.level = :debug
        logger.debug("hello world", payload) { "Calculations" }
        refute logger.events
      end

      it "map debug to trace" do
        logger.level = :trace
        logger.debug("hello world")
        assert log = logger.events.first
        assert_equal :trace, log.level
      end

      it "log trace as trace" do
        logger.level = :trace
        logger.trace("hello world", payload) { "Calculations" }
        assert log = logger.events.first
        assert_equal :trace, log.level
      end
    end
  end
end
