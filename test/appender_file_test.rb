# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'semantic_logger'
require 'stringio'

# Unit Test for SemanticLogger::Appender::File
#
class AppenderFileTest < Test::Unit::TestCase
  context SemanticLogger::Appender::File do
    setup do
      @time = Time.new
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

    context "custom formatter" do
      setup do
        @appender = SemanticLogger::Appender::File.new(@io) do |log|
          message = log.message.to_s
          tags = log.tags.collect { |tag| "[#{tag}]" }.join(" ") + " " if log.tags && (log.tags.size > 0)

          if log.payload
            if log.payload.is_a?(Exception)
              exception = log.payload
              message << " -- " << "#{exception.class}: #{exception.message}\n#{(exception.backtrace || []).join("\n")}"
            else
              message << " -- " << log.payload.inspect
            end
          end

          str = "#{log.time.strftime("%Y-%m-%d %H:%M:%S")}.#{"%03d" % (log.time.usec/1000)} #{log.level.to_s.upcase} [#{$$}:#{log.thread_name}] #{tags}#{log.name} -- #{message}"
          str << " (#{'%.1f' % log.duration}ms)" if log.duration
          str
        end
      end

      should "format using formatter" do
        @appender.debug
        assert_match /\d+-\d+-\d+ \d+:\d+:\d+.\d+ DEBUG \[\d+:#{@thread_name}\] SemanticLogger::Appender::File -- \n/, @io.string
      end
    end

  end
end