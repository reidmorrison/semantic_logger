# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'semantic_logger'
require 'test/mock_logger'

# Unit Test for SemanticLogger::Logger
#
class LoggerTest < Test::Unit::TestCase
  context SemanticLogger::Logger do

    context "log to Ruby and Rails logger" do
      setup do
        # Use a mock logger that just keeps the last logged entry in an instance variable
        @mock_logger = MockLogger.new
        @appender = SemanticLogger::Appender::Logger.new(@mock_logger)
        SemanticLogger::Logger.appenders << @appender

        # Use this test's class name as the application name in the log output
        @logger = SemanticLogger::Logger.new('LoggerTest', :level => :trace)

        @hash = { :tracking_number => 12345, :session_id => 'HSSKLEU@JDK767'}
      end

      teardown do
        SemanticLogger::Logger.appenders.delete(@appender)
      end

      # Ensure that any log level can be logged
      SemanticLogger::Logger::LEVELS.each do |level|
        should "log #{level} info" do
          @logger.send(level, 'hello world', @hash) { "Calculations" }
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:\w+\] LoggerTest -- hello world -- \{:session_id=>\"HSSKLEU@JDK767\", :tracking_number=>12345\} -- Calculations\n/, @mock_logger.message
        end
      end

    end

  end
end