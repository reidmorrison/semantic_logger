require_relative "../test_helper"

# Unit Test for Appender::WrapperTest
module Appender
  class WrapperTest < Minitest::Test
    # Looks like a standard Ruby Logger or Rails Logger
    # Except that it stores the last logged entry in the instance variable: message
    class MockLogger
      attr_accessor :message

      Logger::Severity.constants.each do |level|
        class_eval <<~LEVEL_CODE, __FILE__, __LINE__ + 1
          def #{level.downcase}(message = nil, progname = nil)
            if message
              self.message = message
            elsif block_given?
              self.message = yield
            else
              self.message = progname
            end
            self.message
          end

          def #{level}?
            true
          end
        LEVEL_CODE
      end

      def flush
        true
      end
    end

    describe SemanticLogger::Appender::Wrapper do
      let(:mock_logger) { MockLogger.new }
      let(:appender) { SemanticLogger::Appender::Wrapper.new(logger: mock_logger) }
      let(:ahash) { {session_id: "HSSKLEU@JDK767", tracking_number: 12_345} }
      let(:hash_str) { Regexp.escape(ahash.inspect) }
      let(:file_name_reg_exp) { ' wrapper_test.rb:\d+' }
      let(:log) do
        log         = SemanticLogger::Log.new("User", :info)
        log.message = "hello world"
        log.level   = :info
        log
      end
      let(:backtrace) do
        [
          "test/formatters/default_test.rb:35:in `block (2 levels) in <class:DefaultTest>'"
        ]
      end

      describe "logs" do
        it "blank data" do
          log.message = nil
          log.level   = :debug
          appender.log(log.freeze)

          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+\] User/, mock_logger.message
          )
        end

        it "message" do
          appender.log(log.freeze)

          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:\w+\] User -- hello world/, mock_logger.message
          )
        end

        it "backtrace" do
          log.level     = :warn
          log.backtrace = backtrace
          appender.log(log.freeze)

          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ W \[\d+:\w+\ default_test.rb:35\] User -- hello world/, mock_logger.message
          )
        end

        it "payload" do
          log.level   = :error
          log.payload = ahash
          appender.log(log.freeze)

          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ E \[\d+:\w+\] User -- hello world -- #{hash_str}/, mock_logger.message
          )
        end

        it "trace as debug" do
          log.level = :trace
          appender.log(log.freeze)

          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ T \[\d+:\w+\] User -- hello world/, mock_logger.message
          )
        end

        it "fatal" do
          log.level = :fatal
          appender.log(log.freeze)

          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ F \[\d+:\w+\] User -- hello world/, mock_logger.message
          )
        end
      end

      describe "wrapped_logger" do
        it "is the logger it writes to" do
          assert_same mock_logger, appender.wrapped_logger
        end
      end

      describe "logger" do
        it "is the internal logger every appender reports its own problems to" do
          assert_kind_of SemanticLogger::Subscriber, appender.logger
          assert_equal "SemanticLogger::Appender::Wrapper", appender.logger.name
        end

        it "can be replaced without changing the logger it writes to" do
          appender.logger = SemanticLogger::Test::CaptureLogEvents.new
          appender.log(log)

          assert_match(/User -- hello world/, mock_logger.message)
        end
      end

      describe "async: true" do
        it "writes to the wrapped logger from its own thread" do
          proxy = SemanticLogger::Appender::Async.new(appender: appender)
          proxy.log(log)

          assert proxy.flush, "the worker thread should be running to flush"
          assert_match(/User -- hello world/, mock_logger.message)
        ensure
          proxy&.close
        end

        it "answers wrapped_logger and logger as the appender does, as add_appender returns it" do
          proxy = SemanticLogger.add_appender(logger: mock_logger, async: true)

          assert_instance_of SemanticLogger::Appender::Async, proxy
          assert_same mock_logger, proxy.wrapped_logger
          assert_same proxy.appender.logger, proxy.logger
          refute_same mock_logger, proxy.logger
        ensure
          SemanticLogger.remove_appender(proxy)
        end

        it "does not write its worker thread's own messages to the wrapped logger" do
          mock_logger.define_singleton_method(:trace) { |message = nil, progname = nil| debug(message, progname) }
          proxy = SemanticLogger::Appender::Async.new(appender: appender)

          assert proxy.flush, "the worker thread should be running to flush"
          assert_nil mock_logger.message
        ensure
          proxy&.close
        end
      end
    end
  end
end
