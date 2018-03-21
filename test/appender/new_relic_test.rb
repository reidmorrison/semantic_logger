# So that the NewRelic appender will load the mock
$LOAD_PATH.unshift File.dirname(__FILE__)
require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::NewRelic
module Appender
  class NewRelicTest < Minitest::Test
    describe SemanticLogger::Appender::NewRelic do
      before do
        @appender = SemanticLogger::Appender::NewRelic.new
        @message  = 'AppenderNewRelicTest log message'
      end

      (SemanticLogger::LEVELS - %i[error fatal]).each do |level|
        it "does not send :#{level} notifications to New Relic" do
          exception = hash = nil
          NewRelic::Agent.stub(:notice_error, ->(exc, h) { exception = exc; hash = h }) do
            @appender.tagged('test') do
              @appender.send(level, "AppenderNewRelicTest #{level} message")
            end
          end
          assert_nil exception
          assert_nil hash
        end
      end

      %i[error fatal].each do |level|
        it "sends :#{level} notifications to New Relic" do
          exception = hash = nil
          NewRelic::Agent.stub(:notice_error, ->(exc, h) { exception = exc; hash = h }) do
            @appender.tagged('test') do
              @appender.send(level, @message)
            end
          end
          assert_equal 'RuntimeError', exception.class.to_s
          assert_equal @message, exception.message
          assert_equal ['test'], hash[:custom_params][:tags]
          assert_nil hash[:custom_params][:duration]
          assert hash[:custom_params][:thread], hash.inspect
        end
      end

      it 'send notification to New Relic with custom attributes' do
        exception = hash = nil
        NewRelic::Agent.stub(:notice_error, ->(exc, h) { exception = exc; hash = h }) do
          SemanticLogger.tagged('test') do
            SemanticLogger.named_tagged(key1: 1, key2: 'a') do
              @appender.measure_error(message: @message, payload: {key3: 4}) do
                sleep 0.001
              end
            end
          end
        end
        assert_equal 'RuntimeError', exception.class.to_s
        assert_equal @message, exception.message
        assert params = hash[:custom_params], hash
        assert params[:duration], params
        assert params[:thread], params

        assert_equal ['test'], params[:tags], params

        assert named_tags = params[:named_tags], params
        assert_equal 1, named_tags[:key1], named_tags
        assert_equal 'a', named_tags[:key2], named_tags

        assert payload = params[:payload], params
        assert_equal 4, payload[:key3], payload
      end
    end
  end
end
