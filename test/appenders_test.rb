require_relative "test_helper"

class AppendersTest < Minitest::Test
  class RaisingLogAppender < SemanticLogger::Test::CaptureLogEvents
    def log(_log)
      raise "log boom"
    end
  end

  class RaisingFlushAppender < SemanticLogger::Test::CaptureLogEvents
    def flush
      raise "flush boom"
    end
  end

  class ReopenAppender < SemanticLogger::Test::CaptureLogEvents
    attr_reader :reopened

    def reopen
      @reopened = true
    end
  end

  class RaisingReopenAppender < SemanticLogger::Test::CaptureLogEvents
    def reopen
      raise "reopen boom"
    end
  end

  describe SemanticLogger::Appenders do
    let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
    let(:appenders) { SemanticLogger::Appenders.new(capture_logger) }
    let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

    describe "#add" do
      it "adds file appender" do
        appender = appenders.add(file_name: "sample.log")

        assert_kind_of SemanticLogger::Appender::File, appender
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Default, appender.formatter
      end

      it "adds file appender with json format" do
        appender = appenders.add(file_name: "sample.log", formatter: :json)

        assert_kind_of SemanticLogger::Appender::File, appender
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Json, appender.formatter, appender.formatter.inspect
      end

      it "adds stream appender" do
        appender = appenders.add(io: $stdout)

        assert_kind_of SemanticLogger::Appender::IO, appender
        assert_includes appenders, appender
      end

      it "adds symbol appender" do
        appender = appenders.add(appender: :wrapper, logger: Logger.new($stdout))

        assert_kind_of SemanticLogger::Appender::Wrapper, appender, -> { appender.ai }
        assert_includes appenders, appender
      end

      it "adds symbol appender with underscores" do
        appender = appenders.add(appender: :bugsnag)

        assert_kind_of SemanticLogger::Appender::Bugsnag, appender, -> { appender.ai }
        assert_includes appenders, appender
      end

      it "adds logger wrapper appender" do
        appender = appenders.add(logger: ::Logger.new($stdout))

        assert_kind_of SemanticLogger::Appender::Wrapper, appender
        assert_kind_of ::Logger, appender.logger
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Default, appender.formatter
      end

      it "adds logger wrapper appender with color formatter" do
        appender = appenders.add(logger: ::Logger.new($stdout), formatter: :color)

        assert_kind_of SemanticLogger::Appender::Wrapper, appender
        assert_kind_of ::Logger, appender.logger
        assert_includes appenders, appender
        assert_kind_of SemanticLogger::Formatters::Color, appender.formatter
      end

      it "adds appender" do
        appender = appenders.add(appender: SemanticLogger::Appender::IO.new($stdout))

        assert_kind_of SemanticLogger::Appender::IO, appender, appender.ai
        assert_includes appenders, appender
      end

      it "fails to add invalid logger appender" do
        assert_raises ArgumentError do
          appenders.add(logger: "blah")
        end
      end

      it "prevents adding multiple console loggers" do
        appender = appenders.add(io: $stdout)

        assert_includes appenders, appender

        appender = appenders.add(io: $stdout)

        assert_nil appender

        appender = appenders.add(io: $stderr)

        assert_nil appender

        assert_equal 1, appenders.size
      end

      it "allows adding multiple loggers" do
        appender = appenders.add(io: $stdout)

        assert_includes appenders, appender

        appender = appenders.add(file_name: "test.log")

        assert_includes appenders, appender

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
        appenders.add(file_name: "test.log")

        appenders.close

        assert_equal(0, capture_logger.events.count { |it| it.message.match?(/failed/i) })
        assert_equal 0, appenders.size
      end
    end

    describe "#log" do
      it "continues to remaining appenders when one raises and records the failure" do
        failing   = RaisingLogAppender.new
        recording = SemanticLogger::Test::CaptureLogEvents.new
        appenders << failing
        appenders << recording

        log         = SemanticLogger::Log.new("Test", :info)
        log.message = "hello"
        appenders.log(log)

        assert_includes recording.events, log
        assert(capture_logger.events.any? { |it| it.message.include?("Failed to log to appender") })
      end
    end

    describe "#flush" do
      it "flushes remaining appenders when one raises and records the failure" do
        failing   = RaisingFlushAppender.new
        recording = SemanticLogger::Test::CaptureLogEvents.new
        appenders << failing
        appenders << recording

        appenders.flush

        assert(capture_logger.events.any? { |it| it.message.include?("Failed to flush appender") })
      end
    end

    describe "#reopen" do
      it "reopens appenders that support it and skips those that do not" do
        reopenable     = ReopenAppender.new
        not_reopenable = SemanticLogger::Test::CaptureLogEvents.new
        appenders << reopenable
        appenders << not_reopenable

        appenders.reopen

        assert reopenable.reopened
      end

      it "continues to remaining appenders when one raises and records the failure" do
        failing  = RaisingReopenAppender.new
        succeeds = ReopenAppender.new
        appenders << failing
        appenders << succeeds

        appenders.reopen

        assert succeeds.reopened
        assert(capture_logger.events.any? { |it| it.message.include?("Failed to re-open appender") })
      end
    end
  end
end
