require_relative 'test_helper'
require 'stringio'

class TestAttribute
  include SemanticLogger::Loggable
end

# Unit Test for SemanticLogger::Appender::File
#
class AppenderFileTest < Minitest::Test
  context SemanticLogger::Loggable do
    setup do
      @time = Time.new
      @io = StringIO.new
      @appender = SemanticLogger::Appender::File.new(@io)
      SemanticLogger.default_level = :trace
      SemanticLogger.add_appender(@appender)
      @hash = { :session_id => 'HSSKLEU@JDK767', :tracking_number => 12345 }
      @hash_str = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
      @thread_name = Thread.current.name
    end

    teardown do
      SemanticLogger.remove_appender(@appender)
    end

    context "for each log level" do
      # Ensure that any log level can be logged
      SemanticLogger::LEVELS.each do |level|
        should "log #{level} information with class attribute" do
          TestAttribute.logger.send(level, "hello #{level}", @hash)
          SemanticLogger.flush
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:#{@thread_name}\] TestAttribute -- hello #{level} -- #{@hash_str}\n/, @io.string
        end
        should "log #{level} information with instance attribute" do
          TestAttribute.new.logger.send(level, "hello #{level}", @hash)
          SemanticLogger.flush
          assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ \w \[\d+:#{@thread_name}\] TestAttribute -- hello #{level} -- #{@hash_str}\n/, @io.string
        end
      end
    end

  end
end