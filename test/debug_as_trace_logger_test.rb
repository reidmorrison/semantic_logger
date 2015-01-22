$LOAD_PATH.unshift File.dirname(__FILE__)
require 'test_helper'

# Unit Test for SemanticLogger::Logger
class DebugAsTraceLoggerTest < Minitest::Test
  context SemanticLogger::Logger do
    # Test each filter
    [ nil, /\ALogger/, Proc.new{|l| (/\AExclude/ =~ l.message).nil? } ].each do |filter|
      context "filter: #{filter.class.name}" do
        setup do
          # Use a mock logger that just keeps the last logged entry in an instance
          # variable
          SemanticLogger.default_level = :trace
          @mock_logger = MockLogger.new
          appender = SemanticLogger.add_appender(@mock_logger)
          appender.filter = filter

          # Use this test's class name as the application name in the log output
          @logger   = SemanticLogger::MapDebugToTraceLogger.new(self.class)
          @hash     = { :session_id => 'HSSKLEU@JDK767', :tracking_number => 12345 }
          @hash_str = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
          assert_equal [], @logger.tags
        end

        teardown do
          # Remove all appenders
          SemanticLogger.appenders.each{|appender| SemanticLogger.remove_appender(appender)}
        end

        should 'not log trace when level is debug' do
          @logger.level = :debug
          @logger.trace('hello world', @hash) { "Calculations" }
          SemanticLogger.flush
          assert_nil @mock_logger.message
        end

        should 'not log debug when level is debug' do
          @logger.level = :debug
          @logger.debug('hello world', @hash) { "Calculations" }
          SemanticLogger.flush
          assert_nil @mock_logger.message
        end

        should 'map trace to debug' do
          @logger.level = :trace
          @logger.debug('hello world', @hash) { "Calculations" }
          SemanticLogger.flush
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ T \[\d+:.+\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message
        end

        should 'log trace as trace' do
          @logger.level = :trace
          @logger.trace('hello world', @hash) { "Calculations" }
          SemanticLogger.flush
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ T \[\d+:.+\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message
        end
      end
    end

  end
end