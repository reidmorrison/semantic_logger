require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Http
module Appender
  class HttpTest < Minitest::Test
    response_mock = Struct.new(:code, :body)

    describe SemanticLogger::Appender::Http do
      before do
        @appender = SemanticLogger::Appender::Http.new(url: 'http://localhost:8088/path')
        @message  = 'AppenderHttpTest log message'
      end

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          request = nil
          @appender.http.stub(:request, -> r { request = r; response_mock.new('200', 'ok') }) do
            @appender.send(level, @message)
          end
          message = JSON.parse(request.body)
          assert_equal @message, message['message']
          assert_equal level.to_s, message['level']
          refute message['backtrace']
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
          assert message['message'].include?('Reading File -- NameError: undefined local variable or method'), message['message']
          assert_equal level.to_s, message['level']
          assert message['backtrace'].include?(__FILE__), message['backtrace']
        end

        it "send #{level} custom attributes" do
          request = nil
          @appender.http.stub(:request, -> r { request = r; response_mock.new('200', 'ok') }) do
            @appender.send(level, @message, {key1: 1, key2: 'a'})
          end
          message = JSON.parse(request.body)
          assert_equal @message, message['message']
          assert_equal level.to_s, message['level']
          refute message['backtrace']
          assert_equal(1, message['key1'], message)
          assert_equal('a', message['key2'], message)
        end

      end
    end
  end
end
