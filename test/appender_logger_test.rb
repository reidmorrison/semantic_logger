# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'semantic_logger'
require 'test/mock_logger'

# Unit Test for SemanticLogger::Appender::Logger
#
class AppenderLoggerTest < Test::Unit::TestCase
  context SemanticLogger::Appender::Logger do
    setup do
      @time = Time.parse("2012-08-02 09:48:32.482")
      @mock_logger = MockLogger.new
      @appender = SemanticLogger::Appender::Logger.new(@mock_logger)
      @hash = { :session_id => 'HSSKLEU@JDK767', :tracking_number => 12345 }
    end

    context "format logs into text form" do
      should "handle nil name, message and payload" do
        log = SemanticLogger::Logger::Log.new
        log.time = Time.now
        log.level = :debug
        @appender.log(log)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\]  -- \n/, @mock_logger.message
      end

      should "handle nil message and payload" do
        log = SemanticLogger::Logger::Log.new
        log.time = Time.now
        log.level = :debug
        log.name = 'class'
        @appender.log(log)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\] class -- \n/, @mock_logger.message
      end

      should "handle nil payload" do
        log = SemanticLogger::Logger::Log.new
        log.time = Time.now
        log.level = :debug
        log.name = 'class'
        log.message = 'hello world'
        @appender.log(log)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\] class -- hello world\n/, @mock_logger.message
      end

      should "handle payload" do
        log = SemanticLogger::Logger::Log.new
        log.time = Time.now
        log.level = :debug
        log.name = 'class'
        log.message = 'hello world'
        log.payload = @hash
        @appender.log(log)
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:\] class -- hello world -- \{:session_id=>\"HSSKLEU@JDK767\", :tracking_number=>12345\}\n/, @mock_logger.message
      end
    end

    context "for each log level" do
      # Ensure that any log level can be logged
      Logger::Severity.constants.each do |level|
        should "log #{level.downcase.to_sym} info" do
          @appender.log SemanticLogger::Logger::Log.new(level.downcase.to_sym, 'thread', 'class', 'hello world -- Calculations', @hash, Time.now)
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:thread\] class -- hello world -- Calculations -- \{:session_id=>\"HSSKLEU@JDK767\", :tracking_number=>12345\}\n/, @mock_logger.message
        end
      end
    end

  end
end