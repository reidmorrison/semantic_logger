require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Sentry
module Appender
  class SentryTest < Minitest::Test
    describe SemanticLogger::Appender::Sentry do
      let(:appender) { SemanticLogger::Appender::Sentry.new(level: :trace) }
      let(:amessage) { "AppenderRavenTest log message" }

      SemanticLogger::LEVELS.each do |level|
        it "sends #{level} message" do
          error_message = hash = nil
          Raven.stub(:capture_message, lambda { |msg, h|
            error_message = msg
            hash = h
          }) do
            appender.send(level, amessage)
          end
          assert_equal amessage, error_message
          assert_equal "SemanticLogger::Appender::Sentry", hash[:extra][:name]

          assert hash[:extra].key?(:backtrace)
          assert_equal true, hash.key?(:extra)
          assert_equal level, hash[:level]
        end

        it "sends #{level} exceptions" do
          error     = RuntimeError.new("Oh no, Error.")
          exception = hash = nil
          Raven.stub(:capture_exception, lambda { |exc, h|
            exception = exc
            hash = h
          }) do
            appender.send(level, amessage, error)
          end

          assert_equal error.class.to_s, exception.class.to_s
          assert_equal error.message, exception.message
          assert_equal true, hash.key?(:extra)
          assert_equal amessage, hash[:extra][:message], hash
          assert_equal level, hash[:level]
        end
      end
    end
  end
end
