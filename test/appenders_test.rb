require_relative "test_helper"

class AppendersTest < Minitest::Test
  describe SemanticLogger::Appenders do
    let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:appenders) { SemanticLogger::Appenders.new(capture_logger) }
    let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

    describe "#add" do
      it "adds file appender" do
        appender = appenders.add(file_name: "sample.log")
        assert appender.is_a?(SemanticLogger::Appender::File)
        assert appenders.include?(appender)
        assert appender.formatter.is_a?(SemanticLogger::Formatters::Default)
      end

      it "adds file appender with json format" do
        appender = appenders.add(file_name: "sample.log", formatter: :json)
        assert appender.is_a?(SemanticLogger::Appender::File)
        assert appenders.include?(appender)
        assert appender.formatter.is_a?(SemanticLogger::Formatters::Json), appender.formatter.inspect
      end

      it "adds stream appender" do
        appender = appenders.add(io: $stdout)
        assert appender.is_a?(SemanticLogger::Appender::IO)
        assert appenders.include?(appender)
      end

      it "adds symbol appender" do
        appender = appenders.add(appender: :wrapper, logger: Logger.new($stdout))
        assert appender.is_a?(SemanticLogger::Appender::Wrapper), -> { appender.ai }
        assert appenders.include?(appender)
      end

      it "adds symbol appender with underscores" do
        appender = appenders.add(appender: :bugsnag)
        assert appender.is_a?(SemanticLogger::Appender::Bugsnag), -> { appender.ai }
        assert appenders.include?(appender)
      end

      it "adds logger wrapper appender" do
        appender = appenders.add(logger: ::Logger.new($stdout))
        assert appender.is_a?(SemanticLogger::Appender::Wrapper)
        assert appender.logger.is_a?(::Logger)
        assert appenders.include?(appender)
        assert appender.formatter.is_a?(SemanticLogger::Formatters::Default)
      end

      it "adds logger wrapper appender with color formatter" do
        appender = appenders.add(logger: ::Logger.new($stdout), formatter: :color)
        assert appender.is_a?(SemanticLogger::Appender::Wrapper)
        assert appender.logger.is_a?(::Logger)
        assert appenders.include?(appender)
        assert appender.formatter.is_a?(SemanticLogger::Formatters::Color)
      end

      it "adds appender" do
        appender = appenders.add(appender: SemanticLogger::Appender::IO.new($stdout))
        assert appender.is_a?(SemanticLogger::Appender::IO), appender.ai
        assert appenders.include?(appender)
      end

      it "fails to add invalid logger appender" do
        assert_raises ArgumentError do
          appenders.add(logger: "blah")
        end
      end

      it "prevents adding multiple console loggers" do
        appender = appenders.add(io: $stdout)
        assert appenders.include?(appender)

        appender = appenders.add(io: $stdout)
        assert_nil appender

        appender = appenders.add(io: $stderr)
        assert_nil appender

        assert_equal 1, appenders.size
      end

      it "allows adding multiple loggers" do
        appender = appenders.add(io: $stdout)
        assert appenders.include?(appender)

        appender = appenders.add(file_name: "test.log")
        assert appenders.include?(appender)

        assert_equal 2, appenders.size
      end

      it "adds batch proxy" do
        appender = appenders.add(appender: logger, batch: true)
        assert_instance_of SemanticLogger::Appender::AsyncBatch, appender
      end

      # it "adds async proxy" do
      #   appender = appenders.add(appender: logger, async: true)
      #   assert_instance_of SemanticLogger::Appender::Async, appender
      # end
    end

    describe "#close" do
      it "closes appenders" do
        appender = appenders.add(file_name: "test.log")

        appenders.close

        assert_equal 0, capture_logger.events.count { |it| it.message.match?(/failed/i) }
        assert_equal 0, appenders.size
      end
    end
  end
end
