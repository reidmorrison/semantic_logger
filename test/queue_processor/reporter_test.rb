require_relative "../test_helper"

class ReporterTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::Reporter do
    let(:appender) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:reporter) { SemanticLogger::QueueProcessor::Reporter.new(appender) }
    let(:error) { IOError.new("destination unavailable") }

    it "reports to the internal logger of the appender, with the exception" do
      internal        = SemanticLogger::Test::CaptureLogEvents.new
      appender.logger = internal
      reporter.log(:error, "Could not write", error)

      assert_equal ["Could not write"], internal.events.map(&:message)
      assert_same error, internal.events.first.exception
    end

    it "adds the exception to the message for a logger that takes only the message, such as a Ruby Logger" do
      output          = StringIO.new
      appender.logger = ::Logger.new(output)
      reporter.log(:warn, "Waiting")
      reporter.log(:error, "Could not write", error)

      assert_includes output.string, "WARN -- : Waiting\n"
      assert_includes output.string, "ERROR -- : Could not write -- IOError: destination unavailable\n"
    end

    it "adds an exception whose message is binary, or raises, to a UTF-8 report for such a logger" do
      output          = StringIO.new
      appender.logger = ::Logger.new(output)
      broken          = Class.new(StandardError) do
        def message = raise(NoMethodError, "undefined method 'id' for nil")
      end
      reporter.log(:error, "Écrit", IOError.new("caf\xC3\xA9 \xFF".b))
      reporter.log(:error, "Écrit", broken.new("raised with"))

      assert_includes output.string, "ERROR -- : Écrit -- IOError: café \n"
      assert_match(/ERROR -- : Écrit -- #<Class:0x\h+>: raised with\n/, output.string)
    end

    it "reports once to a logger that takes the exception, even when it raises ArgumentError" do
      # Such as a broadcast logger, one of whose loggers takes only the message, after the others
      # have written the report.
      broadcast = Class.new do
        def calls = @calls ||= []

        def error(*args)
          calls << args
          raise ArgumentError, "wrong number of arguments (given 2, expected 0..1)"
        end
      end.new
      appender.logger = broadcast

      assert_nil reporter.log(:error, "Could not write", error)
      assert_equal [["Could not write", error]], broadcast.calls
    end

    it "ignores an internal logger that cannot take the report" do
      appender.logger = Object.new

      assert_nil reporter.log(:trace, "Active")
      assert_nil reporter.log(:error, "Could not write", error)
    end
  end
end
