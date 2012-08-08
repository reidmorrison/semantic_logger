# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'semantic_logger/appender/logger'
require 'test/mock_logger'

# Unit Test for SemanticLogger::Appender::Logger
#
class AppenderLoggerTest < Test::Unit::TestCase
  context SemanticLogger::Appender::Logger do
    setup do
      @time = Time.parse("2012-08-02 09:48:32.482")
    end

    context "format messages into text form" do
      setup do
        @hash = { :session_id=>"HSSKLEU@JDK767", :tracking_number=>12345 }
      end

      should "handle nil level, application, message and hash" do
        msg = SemanticLogger::Appender::Logger.format_message(nil, nil, nil, nil)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+  \[\d+:\w+\]  -- \n/, msg
      end

      should "handle nil application, message and hash" do
        msg = SemanticLogger::Appender::Logger.format_message(:debug, nil, nil, nil)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+\]  -- \n/, msg
      end

      should "handle nil message and hash" do
        msg = SemanticLogger::Appender::Logger.format_message(:debug, 'application', nil, nil)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+\] application -- \n/, msg
      end

      should "handle nil hash" do
        msg = SemanticLogger::Appender::Logger.format_message(:debug, 'application', 'hello world', nil)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+\] application -- hello world\n/, msg
      end

      should "handle hash" do
        msg = SemanticLogger::Appender::Logger.format_message(:debug, 'application', 'hello world', @hash)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+\] application -- hello world -- \{:session_id=>\"HSSKLEU@JDK767\", :tracking_number=>12345\}\n/, msg
      end

      should "handle block" do
        msg = SemanticLogger::Appender::Logger.format_message(:debug, 'application', 'hello world', @hash) { "Calculations" }
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+\] application -- hello world -- \{:session_id=>\"HSSKLEU@JDK767\", :tracking_number=>12345\} -- Calculations\n/, msg
      end

      should "handle block with no other parameters" do
        msg = SemanticLogger::Appender::Logger.format_message(:debug, nil, nil, nil) { "Calculations" }
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\w+\]  --  -- Calculations\n/, msg
      end
    end

    context "log to Ruby logger" do
      setup do
        @mock_logger = MockLogger.new
        @appender = SemanticLogger::Appender::Logger.new(@mock_logger)
        @hash = { :tracking_number => 12345, :session_id => 'HSSKLEU@JDK767'}
      end

      # Ensure that any log level can be logged
      Logger::Severity.constants.each do |level|
        should "log #{level.downcase.to_sym} info" do
          @appender.log(level.downcase.to_sym, 'application', 'hello world', @hash) { "Calculations" }
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:\w+\] application -- hello world -- \{:session_id=>\"HSSKLEU@JDK767\", :tracking_number=>12345\} -- Calculations\n/, @mock_logger.message
        end
      end

    end

  end
end