require_relative "test_helper"

class SemanticLoggerTest < Minitest::Test
  describe SemanticLogger do
    let(:logger) { SemanticLogger["TestLogger"] }

    describe ".add_appender" do
      before do
        @appender = nil
      end

      after do
        SemanticLogger.remove_appender(@appender)
        FileUtils.rm_f("sample.log")
      end

      it "adds file appender" do
        @appender = SemanticLogger.add_appender(file_name: "sample.log")
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
        assert @appender.formatter.is_a?(SemanticLogger::Formatters::Default)
      end
    end

    describe ".tagged" do
      it "adds one tag" do
        events = semantic_logger_events do
          SemanticLogger.tagged("12345", "DJHSFK") do
            logger.info("Hello World")
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "Hello World",
          tags:    %w[12345 DJHSFK]
        )
      end

      it "add embedded tags" do
        events = semantic_logger_events do
          SemanticLogger.tagged("First Level", "tags") do
            SemanticLogger.tagged("Second Level") do
              logger.info("Hello World")
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "Hello World",
          tags:    ["First Level", "tags", "Second Level"]
        )
      end

      it "adds named tags" do
        events = semantic_logger_events do
          SemanticLogger.tagged(level1: 1) do
            assert_equal({level1: 1}, SemanticLogger.named_tags)
            SemanticLogger.tagged(level2: 2, more: "data") do
              assert_equal({level1: 1, level2: 2, more: "data"}, SemanticLogger.named_tags)
              SemanticLogger.tagged(level3: 3) do
                assert_equal({level1: 1, level2: 2, more: "data", level3: 3}, SemanticLogger.named_tags)
                logger.info("Hello World")
              end
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message:    "Hello World",
          named_tags: {level1: 1, level2: 2, more: "data", level3: 3}
        )
      end
    end

    describe ".named_tags" do
      it "named tags in creation order" do
        SemanticLogger.named_tagged(level1: 1) do
          assert_equal({level1: 1}, SemanticLogger.named_tags)
          SemanticLogger.named_tagged(level2: 2, more: "data") do
            assert_equal({level1: 1, level2: 2, more: "data"}, SemanticLogger.named_tags)
            SemanticLogger.named_tagged(level3: 3) do
              assert_equal({level1: 1, level2: 2, more: "data", level3: 3}, SemanticLogger.named_tags)
            end
          end
        end
      end
    end

    describe ".named_tagged" do
      it "logs named tags in creation order" do
        events = semantic_logger_events do
          SemanticLogger.named_tagged(level1: 1) do
            SemanticLogger.named_tagged(level2: 2, more: "data") do
              SemanticLogger.named_tagged(level3: 3) do
                logger.info("Hello World")
              end
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message:    "Hello World",
          named_tags: {level1: 1, level2: 2, more: "data", level3: 3}
        )
      end
    end

    describe ".fast_tag" do
      it "add string tag to log entries" do
        events = semantic_logger_events do
          logger.fast_tag("12345") do
            logger.info("Hello World")
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "Hello World",
          tags:    %w[12345]
        )
      end
    end

    describe ".default_level" do
      it "uses global default log level" do
        # Uses global default level since logger does not have one set
        SemanticLogger.stub(:default_level, :warn) do
          assert_equal logger.level, :warn
        end
      end

      it "logger retains explicit log level" do
        # Retains the explicit log level even when global log level is different
        logger.level = :trace
        SemanticLogger.stub(:default_level, :warn) do
          assert_equal logger.level, :trace
        end
      end
    end

    describe ".silence" do
      it "not log at a level below the default silence level" do
        events = semantic_logger_events(silence: false) do
          SemanticLogger.stub(:default_level, :info) do
            SemanticLogger.silence do
              logger.fatal("fatal")
              logger.error("error")
              logger.warn("warn")
              logger.info("info")
              logger.debug("debug")
              logger.trace("trace")
            end
          end
        end
        assert_equal %w[fatal error], events.map(&:message)
      end

      it "not log at a level below a specific silence level" do
        events = semantic_logger_events(silence: false) do
          SemanticLogger.stub(:default_level, :info) do
            SemanticLogger.silence(:info) do
              logger.fatal("fatal")
              logger.error("error")
              logger.warn("warn")
              logger.info("info")
              logger.debug("debug")
              logger.trace("trace")
            end
          end
        end
        assert_equal %w[fatal error warn info], events.map(&:message)
      end

      # it "default silence level is :error, so should log everything else" do
      it "silencer is ignored when logger has an explicit log level" do
        logger.level = :trace
        events       = semantic_logger_events(silence: false) do
          SemanticLogger.silence(:debug) do
            logger.fatal("fatal")
            logger.error("error")
            logger.warn("warn")
            logger.info("info")
            logger.debug("debug")
            logger.trace("trace")
          end
        end

        assert_equal %w[fatal error warn info debug trace], events.map(&:message)
      end

      it "log at a silence level below the default level" do
        events = semantic_logger_events(silence: false) do
          SemanticLogger.stub(:default_level, :info) do
            assert_equal :info, logger.level
            logger.silence(:debug) do
              logger.debug("hello world")
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "hello world",
          level:   :debug
        )
      end
    end

    describe ".on_log" do
      after do
        # Clear on_log subscribers
        SemanticLogger::Logger.subscribers.clear
      end

      it "registers a log listener" do
        SemanticLogger.on_log do |log|
          log.set_context(:custom_info, "test")
        end

        events = semantic_logger_events do
          SemanticLogger.stub(:default_level, :info) do
            assert_equal :info, logger.level
            SemanticLogger.silence(:debug) do
              logger.debug("hello world")
            end
          end
        end

        assert_equal 1, events.size
        assert_semantic_logger_event(
          events.first,
          message: "hello world",
          context: {custom_info: "test"}
        )
      end
    end
  end
end
