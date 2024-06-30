require_relative "test_helper"

class SemanticLoggerTest < Minitest::Test
  class BatchAppender < SemanticLogger::Test::CaptureLogEvents
    attr_accessor :batches

    def batch(events)
      (@batches ||= []) << events
    end
  end

  describe SemanticLogger do
    describe ".add_appender" do
      before do
        @appender = nil
      end

      after do
        SemanticLogger.remove_appender(@appender)
        File.delete("sample.log") if File.exist?("sample.log")
      end

      it "adds file appender" do
        @appender = SemanticLogger.add_appender(file_name: "sample.log")
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
        assert @appender.formatter.is_a?(SemanticLogger::Formatters::Default)
      end

      it "adds async appender" do
        @appender = SemanticLogger.add_appender(file_name: "sample.log", async: true)
        assert @appender.is_a?(SemanticLogger::Appender::Async)
        refute @appender.batch?
        assert @appender.appender.is_a?(SemanticLogger::Appender::File)
      end

      it "adds async appender with batch" do
        @appender = SemanticLogger.add_appender(appender: BatchAppender.new, batch: true)
        assert @appender.is_a?(SemanticLogger::Appender::Async)
        assert @appender.batch?
        assert @appender.appender.is_a?(BatchAppender)
      end
    end

    describe "mock_logger" do
      let(:logger) { SemanticLogger::Test::CaptureLogEvents.new }

      describe ".tagged" do
        it "add tags to log entries" do
          SemanticLogger.tagged("12345", "DJHSFK") do
            logger.info("Hello world")

            assert log = logger.events.first
            assert_equal %w[12345 DJHSFK], log.tags
          end
        end

        it "add embedded tags to log entries" do
          SemanticLogger.tagged("First Level", "tags") do
            SemanticLogger.tagged("Second Level") do
              logger.info("Hello world")

              assert log = logger.events.first
              assert_equal ["First Level", "tags", "Second Level"], log.tags
            end
            assert_equal 2, SemanticLogger.tags.count, SemanticLogger.tags
            assert_equal "First Level", SemanticLogger.tags.first
            assert_equal "tags", SemanticLogger.tags.last
          end
        end

        it "also supports named tagging" do
          SemanticLogger.tagged(level1: 1) do
            assert_equal({ level1: 1 }, SemanticLogger.named_tags)
            SemanticLogger.tagged(level2: 2, more: "data") do
              assert_equal({ level1: 1, level2: 2, more: "data" }, SemanticLogger.named_tags)
              SemanticLogger.tagged(level3: 3) do
                assert_equal({ level1: 1, level2: 2, more: "data", level3: 3 }, SemanticLogger.named_tags)
              end
            end
          end
        end
      end

      describe ".named_tags" do
        it "returns named tags in creation order" do
          SemanticLogger.named_tagged(level1: 1) do
            assert_equal({ level1: 1 }, SemanticLogger.named_tags)
            SemanticLogger.named_tagged(level2: 2, more: "data") do
              assert_equal({ level1: 1, level2: 2, more: "data" }, SemanticLogger.named_tags)
              SemanticLogger.named_tagged(level3: 3) do
                assert_equal({ level1: 1, level2: 2, more: "data", level3: 3 }, SemanticLogger.named_tags)
              end
            end
          end
        end
      end

      describe ".named_tagged" do
        it "logs named tags in creation order" do
          SemanticLogger.named_tagged(level1: 1) do
            SemanticLogger.named_tagged(level2: 2, more: "data") do
              SemanticLogger.named_tagged(level3: 3) do
                logger.info("Hello world")

                assert log = logger.events.first
                assert_equal({ level1: 1, level2: 2, more: "data", level3: 3 }, log.named_tags)
              end
            end
          end
        end
      end

      describe ".fast_tag" do
        it "add string tag to log entries" do
          SemanticLogger.fast_tag("12345") do
            logger.info("Hello world")

            assert log = logger.events.first
            assert_equal %w[12345], log.tags
          end
        end
      end

      describe ".default_level" do
        let(:logger) { SemanticLogger::Test::CaptureLogEvents.new(level: nil) }

        it "appender inherits global default level" do
          assert_equal :trace, logger.level
        end

        it "appender inherits updated global default level" do
          SemanticLogger.stub(:default_level_index, 1) do
            assert_equal 1, logger.level_index
            assert logger.debug?
          end
        end

        it "appender can use its own level" do
          logger.level = :error
          assert_equal :error, logger.level
        end
      end

      describe ".silence" do
        let(:logger) { SemanticLogger::Test::CaptureLogEvents.new(level: nil) }

        it "default error level" do
          SemanticLogger.silence do
            logger.warn("Ignore me")
          end
          assert logger.events.empty?
        end

        it "custom level" do
          SemanticLogger.silence(:warn) do
            assert logger.error?
            assert logger.warn?
            refute logger.info?
            refute logger.debug?
            refute logger.trace?
          end
        end
      end

      describe ".on_log" do
        after do
          SemanticLogger::Logger.subscribers.clear
        end

        it "registers a log listener" do
          SemanticLogger.on_log do |log|
            log.set_context(:custom_info, "test")
          end
          logger.debug("hello world")

          assert log = logger.events.first
          assert_equal :debug, log.level
          assert_equal "hello world", log.message
          assert_equal "test", log.context[:custom_info]
        end
      end
    end
  end
end
