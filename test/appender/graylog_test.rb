require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Graylog
module Appender
  class GraylogTest < Minitest::Test
    describe SemanticLogger::Appender::Graylog do
      before do
        @appender = SemanticLogger::Appender::Graylog.new(level: :info)
        @message  = 'AppenderGraylogTest log message'
      end

      (SemanticLogger::LEVELS - [:info, :warn, :error, :fatal]).each do |level|
        it "not send :#{level} notifications to Graylog" do
          hash = nil
          @appender.notifier.stub(:notify!, -> h { hash = h }) do
            @appender.send(level, "AppenderGraylogTest #{level.to_s} message")
          end
          assert_nil hash
        end
      end

      it 'send exception notifications to Graylog with severity' do
        hash = nil
        exc  = nil
        begin
          Uh oh
        rescue Exception => e
          exc = e
        end
        @appender.notifier.stub(:notify!, -> h { hash = h }) do
          @appender.error 'Reading File', exc
        end
        assert_equal 'Reading File', hash[:short_message]
        assert_equal 'NameError', hash[:exception][:name]
        assert_match 'undefined local variable or method', hash[:exception][:message]
        assert_equal 3, hash[:level], 'Should be error level (3)'
        assert hash[:exception][:stack_trace].first.include?(__FILE__), hash[:exception]
      end

      it 'send exception notifications to Graylog without log message' do
        hash = nil
        exc  = nil
        begin
          raise StandardError, 'Reading File'
        rescue Exception => e
          exc = e
        end
        @appender.notifier.stub(:notify!, -> h { hash = h }) do
          @appender.error exc
        end
        assert_equal exc.message, hash[:short_message]
        assert_equal exc.class.to_s, hash[:exception][:name]
        assert_match exc.message, hash[:exception][:message]
        assert_equal 3, hash[:level], 'Should be error level (3)'
        assert hash[:exception][:stack_trace].first.include?(__FILE__), hash[:exception]
      end

      it 'send error notifications to Graylog with severity' do
        hash = nil
        @appender.notifier.stub(:notify!, -> h { hash = h }) do
          @appender.error @message
        end
        assert_equal @message, hash[:short_message]
        assert_equal 3, hash[:level]
        refute hash[:stack_trace]
      end

      it 'send notification to Graylog with custom attributes' do
        hash = nil
        @appender.notifier.stub(:notify!, -> h { hash = h }) do
          @appender.error @message, {key1: 1, key2: 'a'}
        end
        assert_equal @message, hash[:short_message]
        assert_equal 3, hash[:level]
        refute hash[:stack_trace]
        assert payload = hash[:payload], hash
        assert_equal 1, payload[:key1], payload
        assert_equal 'a', payload[:key2], payload
      end
    end
  end
end
