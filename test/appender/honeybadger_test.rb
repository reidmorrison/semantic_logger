require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Bugsnag
module Appender
  class HoneybadgerTest < Minitest::Test
    describe SemanticLogger::Appender::Honeybadger do
      let(:appender) { SemanticLogger::Appender::Honeybadger.new(level: :trace) }
      let(:amessage) { "AppenderHoneybadgerTest log message" }

      # Honeybadger replaces each byte that is not valid UTF-8 with "?".
      it "sends binary text as UTF-8, keeping its characters" do
        hash = nil
        Honeybadger.stub(:notify, ->(h) { hash = h }) do
          appender.error("Café ☕".b, body: "Café \xFF☕".b)
        end

        assert_equal "Café ☕", hash[:error_message]
        assert_equal "Café ☕", hash[:context][:payload][:body]
      end

      it "sends a payload that holds itself, cut off where it repeats" do
        payload        = {name: "loop", body: "Café".b}
        payload[:self] = payload
        hash           = nil
        Honeybadger.stub(:notify, ->(h) { hash = h }) { appender.error("Looped", payload) }

        assert_equal "Café", hash[:context][:payload][:body]
        assert_equal "#<Hash nested too deeply>", hash[:context][:payload][:self][:self]
      end

      it "sends the binary text of an exception's entry as UTF-8" do
        hash = nil
        Honeybadger.stub(:notify, ->(_exception, h) { hash = h }) do
          appender.error("Café ☕".b, RuntimeError.new("boom"))
        end

        assert_equal "Café ☕", hash[:message]
      end

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
          Honeybadger.stub(:notify, lambda { |exc, h|
            exception = exc
            hash = h
          }) do
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
