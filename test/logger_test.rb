# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'semantic_logger'
require 'test/mock_logger'

# Unit Test for SemanticLogger::Logger
class LoggerTest < Test::Unit::TestCase
  context SemanticLogger::Logger do

    context "log to Ruby and Rails logger" do
      setup do
        # Use a mock logger that just keeps the last logged entry in an instance variable
        @mock_logger = MockLogger.new
        @appender = SemanticLogger::Appender::Wrapper.new(@mock_logger)
        SemanticLogger::Logger.appenders << @appender

        # Use this test's class name as the application name in the log output
        @logger = SemanticLogger::Logger.new('LoggerTest', :trace)

        @hash = { :session_id => 'HSSKLEU@JDK767', :tracking_number => 12345 }
        @hash_str = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
      end

      teardown do
        SemanticLogger::Logger.appenders.delete(@appender)
      end

      # Ensure that any log level can be logged
      SemanticLogger::LEVELS.each do |level|
        should "log #{level} info" do
          @logger.send(level, 'hello world', @hash) { "Calculations" }
          SemanticLogger::Logger.flush
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message
        end
      end

      context "with_tags logging" do
        should "add tags to log entries" do
          @logger.with_tags('12345', 'DJHSFK') do
            @logger.info('Hello world')
            SemanticLogger::Logger.flush
            assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \[12345\] \[DJHSFK\] LoggerTest -- Hello world/, @mock_logger.message
          end
        end

        should "add embedded tags to log entries" do
          @logger.with_tags('First Level', 'tags') do
            @logger.with_tags('Second Level') do
              @logger.info('Hello world')
              SemanticLogger::Logger.flush
              assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] \[First Level\] \[tags\] \[Second Level\] LoggerTest -- Hello world/, @mock_logger.message
            end
          end
        end

        should "add payload to log entries" do
          hash = {:tracking_number=>"123456", :even=>2, :more=>"data"}
          hash_str = hash.inspect.sub("{", "\\{").sub("}", "\\}")
          @logger.with_payload(:tracking_number => '123456') do
            @logger.with_payload(:even => 2, :more => 'data') do
              @logger.info('Hello world')
              SemanticLogger::Logger.flush
              assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:.+\] LoggerTest -- Hello world -- #{hash_str}/, @mock_logger.message
            end
          end
        end

        context "Ruby Logger" do
          # Ensure that any log level can be logged
          Logger::Severity.constants.each do |level|
            should "log Ruby logger #{level} info" do
              @logger.level = Logger::Severity.const_get(level)
              if level == 'UNKNOWN'
                assert_equal Logger::Severity.const_get('ERROR')+1, @logger.send(:level_index)
              else
                assert_equal Logger::Severity.const_get(level)+1, @logger.send(:level_index)
              end
            end
          end
        end

      end
    end

  end
end