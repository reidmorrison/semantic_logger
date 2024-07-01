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
      let(:hash_str) { ahash.inspect.sub("{", '\\{').sub("}", '\\}') }
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
    end
  end
end
