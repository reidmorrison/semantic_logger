require_relative "../test_helper"

class CompatibilityTest < Minitest::Test
  describe SemanticLogger::Logger do
    let(:logger) { SemanticLogger["TestLogger"] }

    it "#add" do
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.add(Logger::INFO, "hello world", "progname") { "Data" }
      end

      assert_equal "hello world -- progname -- Data", log.message
      assert_equal :info, log.level
    end

    it "#log" do
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.log(Logger::FATAL, "hello world", "progname") { "Data" }
      end

      assert_equal "hello world -- progname -- Data", log.message
      assert_equal :fatal, log.level
    end

    describe "#info" do
      it "logs message" do
        log = nil
        SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
          logger.info("hello1")
        end

        assert_equal "hello1", log.message
        assert_equal :info, log.level
      end

      it "logs 2 messages" do
        log = nil
        SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
          logger.info("hello1", "hello2")
        end

        assert_equal "hello1 -- hello2", log.message
        assert_equal :info, log.level
      end

      it "logs non-string" do
        log = nil
        SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
          logger.info("hello1", true)
        end

        assert_equal "hello1 -- true", log.message
        assert_equal :info, log.level
      end

      it "logs block result" do
        log = nil
        SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
          logger.info("hello1", true) { "Data" }
        end

        assert_equal "hello1 -- true -- Data", log.message
        assert_equal :info, log.level
      end
    end

    it "#unknown" do
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.unknown("hello world") { "Data" }
      end

      assert_equal "hello world -- Data", log.message
      assert_equal :error, log.level
      assert_equal "TestLogger", log.name
    end

    it "#unknown? as error?" do
      logger.level = :error
      assert logger.unknown?
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.log(Logger::UNKNOWN, "hello world", "progname") { "Data" }
      end

      assert_equal "hello world -- progname -- Data", log.message
      assert_equal :error, log.level
    end

    it "#unknown? as error? when false" do
      logger.level = :fatal
      refute logger.unknown?
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.log(Logger::UNKNOWN, "hello world", "progname") { "Data" }
      end

      refute log
    end

    it "#silence_logger" do
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.silence_logger do
          logger.info "hello world"
        end
      end
      refute log
    end

    it "#<< as info" do
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger << "hello world"
      end

      assert_equal "hello world", log.message
      assert_equal :info, log.level
    end

    it "#progname= as #name=" do
      assert_equal "TestLogger", logger.name
      logger.progname = "NewTest"
      assert_equal "NewTest", logger.name
    end

    it "#progname as #name" do
      assert_equal "TestLogger", logger.name
      assert_equal "TestLogger", logger.progname
    end

    it "#sev_threshold= as #level=" do
      assert_equal :trace, logger.level
      logger.sev_threshold = Logger::DEBUG
      assert_equal :debug, logger.level
    end

    it "#sev_threshold as #level" do
      assert_equal :trace, logger.level
      assert_equal :trace, logger.sev_threshold
    end

    it "#formatter NOOP" do
      assert_nil logger.formatter
      logger.formatter = "blah"
      assert_equal "blah", logger.formatter
    end

    it "#datetime_format NOOP" do
      assert_nil logger.datetime_format
      logger.datetime_format = "blah"
      assert_equal "blah", logger.datetime_format
    end

    it "#close NOOP" do
      logger.close
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.info("hello world")
      end

      assert_equal "hello world", log.message
      assert_equal :info, log.level
    end

    it "#reopen NOOP" do
      logger.reopen
      log = nil
      SemanticLogger::Logger.processor.stub(:log, ->(_log) { log = _log }) do
        logger.info("hello world")
      end

      assert_equal "hello world", log.message
      assert_equal :info, log.level
    end
  end
end
