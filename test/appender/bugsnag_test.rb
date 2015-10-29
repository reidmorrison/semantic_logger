require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Bugsnag
module Appender
  class BugsnagTest < Minitest::Test
    describe SemanticLogger::Appender::Bugsnag do
      before do
        @appender = SemanticLogger::Appender::Bugsnag.new(:warn)
        @message  = 'AppenderBugsnagTest log message'
      end

      (SemanticLogger::LEVELS - [:warn, :error]).each do |level|
        it "not send :#{level} notifications to Bugsnag" do
          exception = hash = nil
          Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
            @appender.send(level, "AppenderBugsnagTest #{level.to_s} message")
          end
          assert_nil exception
          assert_nil hash
        end
      end

      it 'send error notifications to Bugsnag with severity' do
        exception = hash = nil
        Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
          @appender.error @message
        end
        assert_equal 'RuntimeError', exception.class.to_s
        assert_equal @message, exception.message
        assert_equal 'error', hash[:severity]
      end

      it 'send warn notifications to Bugsnag replace warn severity with warning' do
        exception = hash = nil
        Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
          @appender.warn @message
        end
        assert_equal 'RuntimeError', exception.class.to_s
        assert_equal @message, exception.message
        assert_equal 'warning', hash[:severity]
      end

      it 'send notification to Bugsnag with custom attributes' do
        exception = hash = nil
        Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
          @appender.error @message, {key1: 1, key2: 'a'}
        end
        assert_equal 'RuntimeError', exception.class.to_s
        assert_equal @message, exception.message
        assert_equal(1, hash[:key1], hash)
        assert_equal('a', hash[:key2], hash)
      end

      it 'send notification to Bugsnag with exception' do
        error     = RuntimeError.new('Hello World')
        exception = hash = nil
        Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
          @appender.error error
        end
        assert_equal error.class.to_s, exception.class.to_s
        assert_equal error.message, exception.message
      end
    end
  end
end
