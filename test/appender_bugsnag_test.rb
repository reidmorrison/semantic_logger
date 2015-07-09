require_relative 'test_helper'

# Unit Test for SemanticLogger::Appender::Bugsnag
#
class AppenderBugsnagTest < Minitest::Test
  context SemanticLogger::Appender::Bugsnag do
    setup do
      @appender = SemanticLogger::Appender::Bugsnag.new(:warn)
      @message  = 'AppenderBugsnagTest log message'
    end

    (SemanticLogger::LEVELS - [:warn, :error]).each do |level|
      should "not send :#{level} notifications to Bugsnag" do
        message = hash = nil
        Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
          @appender.send(level, "AppenderBugsnagTest #{level.to_s} message")
        end
        assert_nil message
        assert_nil hash
      end
    end

    should "send error notifications to Bugsnag with severity" do
      message = hash = nil
      Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
        @appender.error @message
      end
      assert_equal RuntimeError.new(@message), message
      assert_equal 'error', hash[:severity]
    end

    should 'send warn notifications to Bugsnag replace warn severity with warning' do
      message = hash = nil
      Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
        @appender.warn @message
      end
      assert_equal RuntimeError.new(@message), message
      assert_equal 'warning', hash[:severity]
    end

    should 'send notification to Bugsnag with custom attributes' do
      message = hash = nil
      Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
        @appender.error @message, {:key1 => 1, :key2 => 'a'}
      end
      assert_equal RuntimeError.new(@message), message
      assert_equal(1, hash[:key1], hash)
      assert_equal('a', hash[:key2], hash)
    end

    should 'send notification to Bugsnag with exception' do
      message = hash = nil
      error = RuntimeError.new('Hello World')
      Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
        @appender.error error
      end
      assert_equal error, message
    end
  end
end
