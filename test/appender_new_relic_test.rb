# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'
# Load mocked newrelic_rpm from test directory
$LOAD_PATH.unshift File.dirname(__FILE__)


require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'mocha/setup'
require 'semantic_logger'

# Unit Test for SemanticLogger::Appender::NewRelic
#
class AppenderNewRelicTest < Test::Unit::TestCase
  context SemanticLogger::Appender::NewRelic do

    setup do
      @appender = SemanticLogger::Appender::NewRelic.new
      @message  = 'AppenderNewRelicTest log message'
      @multi_line_message = <<-EOSTR


      first non-blank line
      second non-blank line

      third non-blank line

      EOSTR
    end

    (SemanticLogger::LEVELS - [:error, :fatal]).each do |level|
      should "not send :#{level.to_s} notifications to New Relic" do
        @appender.tagged('test') do
          @appender.send(level, "AppenderNewRelicTest #{level.to_s} message")
        end
        assert_nil ::NewRelic::Agent.message
        assert_nil ::NewRelic::Agent.hash, ::NewRelic::Agent.hash
      end
    end

    [:error, :fatal].each do |level|
      should "send :#{level.to_s} notifications to New Relic" do
      @appender.tagged('test') do
        @appender.send(level, @message)
      end
      assert_equal @message, ::NewRelic::Agent.message
      assert_equal ['test'], ::NewRelic::Agent.hash[:custom_params][:tags], ::NewRelic::Agent.hash
      assert_equal "SemanticLogger::Appender::NewRelic/#{@message}", ::NewRelic::Agent.hash[:metric]
      assert_nil ::NewRelic::Agent.hash[:custom_params][:duration], ::NewRelic::Agent.hash
      assert_not_nil ::NewRelic::Agent.hash[:custom_params][:thread_name], ::NewRelic::Agent.hash
      end
    end

    should 'send notification to New Relic with custom attributes' do
      @appender.tagged('test') do
        @appender.with_payload({:key1 => 1, :key2 => 'a'}) do
          @appender.benchmark(:error, @message) do
            sleep 0.001
          end
        end
      end
      assert_equal @message, ::NewRelic::Agent.message
      assert_equal ['test'], ::NewRelic::Agent.hash[:custom_params][:tags], ::NewRelic::Agent.hash
      assert_equal "SemanticLogger::Appender::NewRelic/#{@message}", ::NewRelic::Agent.hash[:metric]
      assert_equal({:key1 => 1, :key2 => 'a'}, ::NewRelic::Agent.hash[:custom_params][:payload], ::NewRelic::Agent.hash)
      assert_not_nil ::NewRelic::Agent.hash[:custom_params][:duration], ::NewRelic::Agent.hash
      assert_not_nil ::NewRelic::Agent.hash[:custom_params][:thread_name], ::NewRelic::Agent.hash
    end

    should 'use the first non-blank line for a multi-line message' do
      @appender.tagged('test') do
        @appender.error @multi_line_message
      end
      assert_equal 'first non-blank line', ::NewRelic::Agent.message
    end

  end
end
