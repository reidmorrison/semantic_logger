require_relative '../test_helper'

# Unit Test for SemanticLogger::Appender::Bugsnag
module Appender
  class HoneybadgerTest < Minitest::Test
    describe SemanticLogger::Appender::Honeybadger do
      before do
        @appender = SemanticLogger::Appender::Honeybadger.new(:trace)
        @message  = 'AppenderHoneybadgerTest log message'
      end

      SemanticLogger::LEVELS.each do |level|
        it "sends #{level} message" do
          hash = nil
          Honeybadger.stub(:notify, -> h { hash = h }) do
            @appender.send(level, @message)
          end
          assert_equal @message, hash[:error_message]
          assert_equal 'SemanticLogger::Appender::Honeybadger', hash[:error_class]
          assert_equal true, hash.has_key?(:backtrace)
          assert_equal true, hash.has_key?(:context)
          assert_equal level, hash[:context][:level]
        end

        it "sends #{level} exceptions" do
          error     = RuntimeError.new('Oh no, Error.')
          exception = hash = nil
          Honeybadger.stub(:notify, -> exc, h { exception = exc; hash = h }) do
            @appender.send(level, @message, error)
          end

          assert_equal error.class.to_s, exception.class.to_s
          assert_equal error.message, exception.message
          assert_equal @message, hash[:message], hash
        end
      end

    end
  end
end
