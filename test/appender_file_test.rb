# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'semantic_logger'
require 'test/mock_logger'

# Unit Test for SemanticLogger::Appender::File
#
class AppenderFileTest < Test::Unit::TestCase
  context SemanticLogger::Appender::File do
    setup do
      @time = Time.parse("2012-08-02 09:48:32.482")
      @io = StringIO.new
      @appender = SemanticLogger::Appender::File.new(@io)
      @hash = { :session_id => 'HSSKLEU@JDK767', :tracking_number => 12345 }
      @hash_str = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
      @thread_name = SemanticLogger::Base.thread_name
    end

    context "format logs into text form" do
      should "handle no message or payload" do
        @appender.debug
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- \n/, @io.string
      end

      should "handle message" do
        @appender.debug 'hello world'
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- hello world\n/, @io.string
      end

      should "handle message and payload" do
        @appender.debug 'hello world', @hash
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- hello world -- #{@hash_str}\n/, @io.string
      end
    end

    context "for each log level" do
      # Ensure that any log level can be logged
      SemanticLogger::LEVELS.each do |level|
        should "log #{level} information" do
          @appender.send(level, 'hello world', @hash)
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- hello world -- #{@hash_str}\n/, @io.string
        end
      end
    end

  end
end