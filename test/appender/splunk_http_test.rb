require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::SplunkHttp
module Appender
  class SplunkHttpTest < Minitest::Test
    response_mock = Struct.new(:code, :body)

    describe SemanticLogger::Appender::SplunkHttp do
      before do
        @appender = SemanticLogger::Appender::SplunkHttp.new(
          url:   'http://localhost:8088/path',
          token: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
        )
        @message  = 'AppenderSplunkHttpTest log message'
      end

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          request = nil
          @appender.http.stub(:request, -> r { request = r; response_mock.new('200', 'ok') }) do
            @appender.send(level, @message)
          end
          message = JSON.parse(request.body)
          assert_equal @message, message['event']['message']
          assert_equal level.to_s, message['event']['level']
          refute message['event']['backtrace']
        end

        it "send #{level} exceptions" do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          request = nil
          @appender.http.stub(:request, -> r { request = r; response_mock.new('200', 'ok') }) do
            @appender.send(level, 'Reading File', exc)
          end
          message = JSON.parse(request.body)
          assert message['event']['message'].include?('Reading File -- NameError: undefined local variable or method'), message['message']
          assert_equal level.to_s, message['event']['level']
          assert message['event']['backtrace'].include?(__FILE__), message['event']['backtrace']
        end

        it "send #{level} custom attributes" do
          request = nil
          @appender.http.stub(:request, -> r { request = r; response_mock.new('200', 'ok') }) do
            @appender.send(level, @message, {key1: 1, key2: 'a'})
          end
          message = JSON.parse(request.body)
          assert_equal @message, message['event']['message']
          assert_equal level.to_s, message['event']['level']
          refute message['event']['backtrace']
          assert_equal(1, message['event']['key1'], message)
          assert_equal('a', message['event']['key2'], message)
        end

      end
    end
  end
end
