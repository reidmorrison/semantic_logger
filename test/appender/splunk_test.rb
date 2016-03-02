require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Splunk
#
module Appender
  class SplunkTest < Minitest::Test

    class Mock
      attr_accessor :message, :event

      def submit(message, event)
        self.message = message
        self.event   = event
      end
    end

    describe SemanticLogger::Appender::Splunk do
      before do
        SemanticLogger::Appender::Splunk.stub_any_instance(:reopen, nil) do
          @appender = SemanticLogger::Appender::Splunk.new(level: :info)
        end
        @message = 'AppenderSplunkTest log message'
      end

      it 'not send :trace notifications to Splunk when set to :error' do
        mock = Mock.new
        @appender.stub(:service_index, mock) do
          @appender.trace('AppenderSplunkTest trace message')
        end
        assert_nil mock.event
        assert_nil mock.message
      end

      it 'send exception notifications to Splunk with severity' do
        hash = nil
        exc  = nil
        begin
          Uh oh
        rescue Exception => e
          exc = e
        end
        mock = Mock.new
        @appender.stub(:service_index, mock) do
          @appender.error 'Reading File', exc
        end
        assert_equal 'Reading File', mock.message
        hash = mock.event
        refute hash[:message]
        assert 'NameError', hash[:exception][:name]
        assert 'undefined local variable or method', hash[:exception][:message]
        assert_equal 4, hash[:level_index], 'Should be error level (4)'
        assert_equal :error, hash[:level]
        assert hash[:exception][:stack_trace].first.include?(__FILE__), hash[:exception]
      end

      it 'send error notifications to Splunk with severity' do
        mock = Mock.new
        @appender.stub(:service_index, mock) do
          @appender.error @message
        end
        assert_equal @message, mock.message
        assert_equal :error, mock.event[:level]
        refute mock.event[:stack_trace]
      end

      it 'send notification to Splunk with custom attributes' do
        mock = Mock.new
        @appender.stub(:service_index, mock) do
          @appender.error @message, {key1: 1, key2: 'a'}
        end
        assert_equal @message, mock.message
        hash = mock.event
        assert_equal :error, hash[:level]
        refute hash[:stack_trace]
        assert_equal(1, hash[:key1], hash)
        assert_equal('a', hash[:key2], hash)
      end

    end
  end
end
