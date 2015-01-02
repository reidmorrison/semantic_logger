$LOAD_PATH.unshift File.dirname(__FILE__)
require 'test_helper'

# Unit Test for SemanticLogger::Appender::NewRelic
#
class AppenderNewRelicTest < Minitest::Test
  context SemanticLogger::Appender::NewRelic do

    setup do
      @appender = SemanticLogger::Appender::NewRelic.new(:error)
      @message  = 'AppenderNewRelicTest log message'
      @multi_line_message = <<-EOSTR


      first non-blank line
      second non-blank line

      third non-blank line

      EOSTR
    end

    (SemanticLogger::LEVELS - [:error, :fatal]).each do |level|
      should "not send :#{level.to_s} notifications to New Relic" do
        message = hash = nil
        NewRelic::Agent.stub(:notice_error, -> msg, h { message = msg; hash = h }) do
          @appender.tagged('test') do
            @appender.send(level, "AppenderNewRelicTest #{level.to_s} message")
          end
        end
        assert_nil message
        assert_nil hash
      end
    end

    [:error, :fatal].each do |level|
      should "send :#{level.to_s} notifications to New Relic" do
        message = hash = nil
        NewRelic::Agent.stub(:notice_error, -> msg, h { message = msg; hash = h }) do
          @appender.tagged('test') do
            @appender.send(level, @message)
          end
        end
        assert_equal @message, message
        assert_equal ['test'], hash[:custom_params][:tags]
        assert_equal "SemanticLogger::Appender::NewRelic/#{@message}", hash[:metric]
        assert_nil hash[:custom_params][:duration]
        assert hash[:custom_params][:thread_name], hash.inspect
      end
    end

    should 'send notification to New Relic with custom attributes' do
      message = hash = nil
      NewRelic::Agent.stub(:notice_error, -> msg, h { message = msg; hash = h }) do
        @appender.tagged('test') do
          @appender.with_payload({:key1 => 1, :key2 => 'a'}) do
            @appender.benchmark(:error, @message) do
              sleep 0.001
            end
          end
        end
      end
      assert_equal @message, message
      assert_equal ['test'], hash[:custom_params][:tags], hash
      assert_equal "SemanticLogger::Appender::NewRelic/#{@message}", hash[:metric]
      assert_equal({:key1 => 1, :key2 => 'a'}, hash[:custom_params][:payload], hash)
      assert hash[:custom_params][:duration], hash
      assert hash[:custom_params][:thread_name], hash
    end

    should 'use the first non-blank line for a multi-line message' do
      message = hash = nil
      NewRelic::Agent.stub(:notice_error, -> msg, h { message = msg; hash = h }) do
        @appender.tagged('test') do
          @appender.error @multi_line_message
        end
      end
      assert_equal 'first non-blank line', message
    end

  end
end
