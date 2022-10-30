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
      let(:ahash) { { session_id: "HSSKLEU@JDK767", tracking_number: 12_345 } }
      let(:hash_str) { ahash.inspect.sub("{", '\\{').sub("}", '\\}') }
      let(:file_name_reg_exp) { ' wrapper_test.rb:\d+' }
      let(:log) do
        log         = SemanticLogger::Log.new("User", :info)
        log.message = "hello world"
        log.level   = :info
        log
      end

      before do
        Thread.current.name = Thread.current.object_id
      end

      describe "logs" do
        it "blank data" do
          appender.debug
          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SemanticLogger::Appender::Wrapper/, mock_logger.message
          )
        end

        it "message" do
          appender.info("hello world")
          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:\w+#{file_name_reg_exp}\] SemanticLogger::Appender::Wrapper -- hello world/, mock_logger.message
          )
        end

        it "message and payload" do
          appender.warn("hello world", ahash)
          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ W \[\d+:\w+#{file_name_reg_exp}\] SemanticLogger::Appender::Wrapper -- hello world -- #{hash_str}/, mock_logger.message
          )
        end

        it "named parameters" do
          appender.error(message: "hello world", payload: ahash)
          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ E \[\d+:\w+#{file_name_reg_exp}\] SemanticLogger::Appender::Wrapper -- hello world -- #{hash_str}/, mock_logger.message
          )
        end

        it "trace as debug" do
          appender.trace("hello world")
          assert_match(
            /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+#{file_name_reg_exp}\] SemanticLogger::Appender::Wrapper -- hello world/, mock_logger.message
          )
        end
      end
    end
  end
end
