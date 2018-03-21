require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Wrapper
#
module Appender
  class WrapperTest < Minitest::Test
    # Looks like a standard Ruby Logger or Rails Logger
    # Except that it stores the last logged entry in the instance variable: message
    class MockLogger
      attr_accessor :message

      Logger::Severity.constants.each do |level|
        class_eval <<-EOT, __FILE__, __LINE__
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
          @true
        end
        EOT
      end

      def flush
        true
      end
    end

    describe SemanticLogger::Appender::Wrapper do
      before do
        SemanticLogger.default_level   = :trace
        SemanticLogger.backtrace_level = :trace

        @time              = Time.new
        @mock_logger       = MockLogger.new
        @appender          = SemanticLogger::Appender::Wrapper.new(logger: @mock_logger)
        @hash              = {session_id: 'HSSKLEU@JDK767', tracking_number: 12_345}
        @hash_str          = @hash.inspect.sub('{', '\\{').sub('}', '\\}')
        @thread_name       = Thread.current.name
        @file_name_reg_exp = ' wrapper_test.rb:\d+'
      end

      describe 'format logs into text form' do
        it 'logs blank data' do
          @appender.debug
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}#{@file_name_reg_exp}\] SemanticLogger::Appender::Wrapper/, @mock_logger.message)
        end

        it 'logs message' do
          @appender.debug('hello world')
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}#{@file_name_reg_exp}\] SemanticLogger::Appender::Wrapper -- hello world/, @mock_logger.message)
        end

        it 'logs message and payload' do
          @appender.debug('hello world', @hash)
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}#{@file_name_reg_exp}\] SemanticLogger::Appender::Wrapper -- hello world -- #{@hash_str}/, @mock_logger.message)
        end

        it 'logs named parameters' do
          @appender.debug(message: 'hello world', payload: @hash)
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}#{@file_name_reg_exp}\] SemanticLogger::Appender::Wrapper -- hello world -- #{@hash_str}/, @mock_logger.message)
        end
      end

      describe 'for each log level' do
        before do
          @appender = SemanticLogger.add_appender(logger: @mock_logger)
          @logger   = SemanticLogger[WrapperTest]
        end

        after do
          SemanticLogger.remove_appender(@appender)
        end

        # Ensure that any log level can be logged
        Logger::Severity.constants.each do |level|
          it "log #{level.downcase.to_sym}" do
            level_char = level[0].upcase
            level_char = 'E' if level_char == 'U'
            @logger.send(level.downcase.to_sym, 'hello world', @hash)
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}#{@file_name_reg_exp}\] Appender::WrapperTest -- hello world -- #{@hash_str}/, @mock_logger.message)
          end
        end
      end
    end
  end
end
