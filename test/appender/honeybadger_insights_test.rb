require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::HoneybadgerInsights
module Appender
  class HoneybadgerInsightsTest < Minitest::Test
    describe SemanticLogger::Appender::HoneybadgerInsights do
      before do
        @appender = SemanticLogger::Appender::HoneybadgerInsights.new(level: :trace)
        @message = "AppenderHoneybadgerInsightsTest log message"
      end

      SemanticLogger::Levels::LEVELS.each do |level|
        it "sends :#{level} notifications to Honeybadger" do
          hash = nil
          Honeybadger.stub(:event, ->(h) { hash = h }) do
            @appender.send(level, @message)
          end

          refute_nil hash[:ts]
          assert_equal @message, hash[:message]
          assert_equal level, hash[:level]
        end

        it "includes an event_type of 'log' in the notification" do
          hash = nil
          Honeybadger.stub(:event, ->(h) { hash = h }) do
            @appender.send(level, @message)
          end

          assert_equal "log", hash[:event_type]
        end
      end

      # Honeybadger replaces each byte that is not valid UTF-8 with "?".
      it "sends binary text as UTF-8, keeping its characters" do
        hash = nil
        Honeybadger.stub(:event, ->(h) { hash = h }) do
          @appender.info("Café ☕".b, body: "Café \xFF☕".b)
        end

        assert_equal "Café ☕", hash[:message]
        assert_equal "Café ☕", hash[:payload][:body]
        assert_equal "log", hash[:event_type]
      end

      it "sends a payload that holds itself, cut off where it repeats" do
        payload        = {name: "loop", body: "Café".b}
        payload[:self] = payload
        hash           = nil
        Honeybadger.stub(:event, ->(h) { hash = h }) { @appender.info("Looped", payload) }

        assert_equal "Café", hash[:payload][:body]
        assert_equal "#<Hash nested too deeply>", hash[:payload][:self][:self]
      end

      it "send notification to Honeybadger with custom attributes" do
        hash = nil
        Honeybadger.stub(:event, ->(h) { hash = h }) do
          SemanticLogger.tagged("test") do
            SemanticLogger.named_tagged(key1: 1, key2: "a") do
              @appender.measure_error(message: @message, payload: {key3: 4}) do
                sleep 0.001
              end
            end
          end
        end

        refute_nil hash[:ts]
        assert_equal @message, hash[:message]
        assert_equal :error, hash[:level]

        assert_equal ["test"], hash[:tags]

        assert_equal 1, hash[:named_tags][:key1]
        assert_equal "a", hash[:named_tags][:key2]

        refute_nil hash[:duration]
        refute_nil hash[:duration_ms]

        assert_equal 4, hash[:payload][:key3]
      end
    end
  end
end
