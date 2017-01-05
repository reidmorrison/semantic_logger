require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Bugsnag
module Appender
  class BugsnagTest < Minitest::Test
    describe SemanticLogger::Appender::Bugsnag do
      before do
        @appender = SemanticLogger::Appender::Bugsnag.new(:info)
        @message  = 'AppenderBugsnagTest log message'
      end

      SemanticLogger::LEVELS.each do |level|
        it "sends #{level} message" do
          bugsnag_level =
            case level
            when :warn
              'warning'
            when :fatal
              'error'
            else
              level.to_s
            end
          exception     = hash = nil
          Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
            @appender.send(level, @message)
          end
          if [:trace, :debug].include?(level)
            assert_nil exception
            assert_nil hash
          else
            assert_equal 'RuntimeError', exception.class.to_s
            assert_equal @message, exception.message
            assert_equal bugsnag_level.to_s, hash[:severity]
          end
        end

        it "sends #{level} custom attributes" do
          exception = hash = nil
          Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
            @appender.send(level, @message, {key1: 1, key2: 'a'})
          end
          if [:trace, :debug].include?(level)
            assert_nil exception
            assert_nil hash
          else
            assert_equal 'RuntimeError', exception.class.to_s
            assert_equal @message, exception.message
            assert payload = hash[:payload], hash
            assert_equal 1, payload[:key1], payload
            assert_equal 'a', payload[:key2], payload
          end
        end

        it "sends #{level} exceptions" do
          error     = RuntimeError.new('Hello World')
          exception = hash = nil
          Bugsnag.stub(:notify, -> exc, h { exception = exc; hash = h }) do
            @appender.send(level, @message, error)
          end
          if [:trace, :debug].include?(level)
            assert_nil exception
            assert_nil hash
          else
            assert_equal error.class.to_s, exception.class.to_s
            assert_equal error.message, exception.message
            assert_equal @message, hash[:message], hash
          end
        end
      end

    end
  end
end
