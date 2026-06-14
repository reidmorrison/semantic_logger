require_relative "test_helper"

module SemanticLogger
  class SyncProcessorTest < Minitest::Test
    describe SemanticLogger::SyncProcessor do
      let(:appender) { SemanticLogger::Test::CaptureLogEvents.new }
      let(:processor) do
        SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new.tap { |a| a << appender })
      end

      describe ".logger" do
        it "defaults to a warn level IO appender named after the class" do
          assert_kind_of SemanticLogger::Appender::IO, SemanticLogger::SyncProcessor.logger
          assert_equal :warn, SemanticLogger::SyncProcessor.logger.level
          assert_equal "SemanticLogger::SyncProcessor", SemanticLogger::SyncProcessor.logger.name
        end
      end

      describe ".logger=" do
        it "allows the internal logger to be overridden" do
          original = SemanticLogger::SyncProcessor.logger
          begin
            replacement = SemanticLogger::Appender::IO.new($stdout)
            SemanticLogger::SyncProcessor.logger = replacement
            assert_same replacement, SemanticLogger::SyncProcessor.logger
          ensure
            SemanticLogger::SyncProcessor.logger = original
          end
        end
      end

      describe "#initialize" do
        it "creates its own Appenders collection when none is supplied" do
          assert_kind_of SemanticLogger::Appenders, SemanticLogger::SyncProcessor.new.appenders
        end

        it "uses the supplied appenders" do
          assert_includes processor.appenders, appender
        end
      end

      describe "#add" do
        it "adds an appender" do
          added = processor.add(io: $stdout)
          assert_includes processor.appenders, added
        end
      end

      describe "#log" do
        it "logs synchronously on the calling thread" do
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = "hello"
          processor.log(log)
          assert_includes appender.events, log
        end
      end

      describe "#flush, #close, #reopen" do
        it "delegate to the appenders" do
          mock = Minitest::Mock.new
          mock.expect(:flush, nil)
          mock.expect(:close, nil)
          mock.expect(:reopen, nil)

          sync = SemanticLogger::SyncProcessor.new(mock)
          sync.flush
          sync.close
          sync.reopen

          mock.verify
        end
      end

      describe "#start" do
        it "is a no-op" do
          assert_nil processor.start
        end
      end
    end
  end
end
