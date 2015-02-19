$LOAD_PATH.unshift File.dirname(__FILE__)
require 'test_helper'

# Unit Test for SemanticLogger::Appender::Bugsnag
#
class AppenderBugsnagTest < Minitest::Test
  context SemanticLogger::Appender::Bugsnag do
    setup do
      @appender = SemanticLogger::Appender::Bugsnag.new(:error)
      @message  = 'AppenderBugsnagTest log message'
    end

    (SemanticLogger::LEVELS - [:error, :fatal]).each do |level|
      should "not send :#{level} notifications to Bugsnag" do
        message = hash = nil
        Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
          @appender.send(level, "AppenderBugsnagTest #{level.to_s} message")
        end
        assert_nil message
        assert_nil hash
      end
    end

    [:error, :fatal].each do |level|
      should "send :#{level} notifications to Bugsnag with severity" do
        message = hash = nil
        Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
          @appender.send(level, @message)
        end
        assert_equal @message, message
        assert_equal level.to_s, hash[:severity]
      end
    end

    should 'replace warn severity with warning' do
      message = hash = nil
      Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
        SemanticLogger::Appender::Bugsnag.new(:warn).warn @message
      end
      assert_equal @message, message
      assert_equal 'warning', hash[:severity]
    end

    should 'send notification to Bugsnag with custom attributes' do
      message = hash = nil
      Bugsnag.stub(:notify, -> msg, h { message = msg; hash = h }) do
        @appender.error @message, {:key1 => 1, :key2 => 'a'}
      end
      assert_equal @message, message
      assert_equal(1, hash[:key1], hash)
      assert_equal('a', hash[:key2], hash)
    end
  end
end
