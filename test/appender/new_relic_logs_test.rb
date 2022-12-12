require_relative "../test_helper"

add_mocks_to_load_path

# Unit Test for SemanticLogger::Appender::NewRelicLogs
module Appender
  class NewRelicLogsTest < Minitest::Test
    describe SemanticLogger::Appender::NewRelicLogs do
      before do
        @appender = SemanticLogger::Appender::NewRelicLogs.new
        @message  = "AppenderNewRelicTest log message"
      end

      def log_newrelic_stub(message, level)
        @logged_message = message
        @logged_level = level
        @hash = JSON.parse(@logged_message)
        @message_hash = JSON.parse(@hash["message"])
      end

      SemanticLogger::Levels::LEVELS.each do |level|
        it "sends :#{level} notifications to New Relic" do
          NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
            @appender.tagged("test") do
              @appender.send(level, @message)
            end
          end

          assert_equal @message, @message_hash["message"]
          assert_equal ["test"], @message_hash["tags"]
          assert_nil @message_hash["duration"]
          assert @hash["thread.name"], @hash.inspect
          assert_equal @logged_level, level.to_s.upcase
        end
      end

      it "send notification to New Relic with custom attributes" do
        SemanticLogger::Appender::NewRelicLogs.stub(:log_newrelic, method(:log_newrelic_stub)) do
          SemanticLogger.tagged("test") do
            SemanticLogger.named_tagged(key1: 1, key2: "a") do
              @appender.measure_error(message: @message, payload: {key3: 4}) do
                sleep 0.001
              end
            end
          end
        end

        assert @hash["thread.name"], @hash.inspect

        assert params = @message_hash, hash
        assert_equal @message, params["message"]
        assert params["duration"], params
        assert_equal ["test"], params["tags"], params

        assert named_tags = params["named_tags"], params
        assert_equal 1, named_tags["key1"], named_tags
        assert_equal "a", named_tags["key2"], named_tags

        assert payload = params["payload"], params
        assert_equal 4, payload["key3"], payload
      end
    end
  end
end
