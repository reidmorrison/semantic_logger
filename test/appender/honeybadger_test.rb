require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Bugsnag
module Appender
  class HoneybadgerTest < Minitest::Test
    describe SemanticLogger::Appender::Honeybadger do
      let(:appender) { SemanticLogger::Appender::Honeybadger.new(level: :trace) }
      let(:amessage) { "AppenderHoneybadgerTest log message" }

      SemanticLogger::LEVELS.each do |level|
        it "sends #{level} message" do
          hash = nil
          Honeybadger.stub(:notify, ->(h) { hash = h }) do
            appender.send(level, amessage)
          end
          assert_equal amessage, hash[:error_message]
          assert_equal "SemanticLogger::Appender::Honeybadger", hash[:error_class]

          assert hash.key?(:backtrace)
          assert_equal true, hash.key?(:context)
          assert_equal level, hash[:context][:level]
        end

        it "sends #{level} exceptions" do
          error     = RuntimeError.new("Oh no, Error.")
          exception = hash = nil
          Honeybadger.stub(:notify, ->(exc, h) { exception = exc; hash = h }) do
            appender.send(level, amessage, error)
          end

          assert_equal error.class.to_s, exception.class.to_s
          assert_equal error.message, exception.message
          assert_equal amessage, hash[:message], hash
        end
      end
    end
  end
end
