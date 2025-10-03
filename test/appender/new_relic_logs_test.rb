require_relative "../test_helper"

add_mocks_to_load_path

# Unit Test for SemanticLogger::Appender::NewRelicLogs
module Appender
  class NewRelicLogsTest < Minitest::Test
    describe SemanticLogger::Appender::NewRelicLogs do
      before do
        @appender = SemanticLogger::Appender::NewRelicLogs.new
        @message  = "AppenderNewRelicTest log message"
        NewRelic::Agent.metadata_enabled = true
      end

      after do
        NewRelic::Agent.metadata_enabled = false
      end

      def log_newrelic_stub(message, level)
        @logged_message = message
        @logged_level = level
      end

      def parse_logged_message
        @hash = begin
          JSON.parse(@logged_message)
        rescue StandardError
          nil
        end
        begin
          @message_hash = JSON.parse(@hash["message"]) if @hash && @hash["message"].is_a?(String)
        rescue StandardError
          nil
        end
      end

      SemanticLogger::Levels::LEVELS.each do |level|
        it "sends :#{level} notifications to New Relic" do
          NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
            @appender.tagged("test") do
              @appender.send(level, @message)
            end
          end

          parse_logged_message
          refute_nil @hash, "Expected @hash to be parsed JSON"
          assert_equal @message, @hash["message"]
          assert_equal ["test"], @hash["tags"]
          assert_nil @hash.dig("duration", "ms")
          assert @hash.dig("thread", "name"), @hash.inspect
          assert_equal @logged_level, level.to_s.upcase
        end
      end

      it "sends notification to New Relic with custom attributes" do
        SemanticLogger::Appender::NewRelicLogs.stub(:log_newrelic, method(:log_newrelic_stub)) do
          SemanticLogger.tagged("test") do
            SemanticLogger.named_tagged(key1: 1, key2: "a") do
              @appender.measure_error(message: @message, payload: {key3: 4}) do
                sleep 0.001
              end
            end
          end
        end

        parse_logged_message
        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal @message, @hash["message"]
        assert_equal ["test"], @hash["tags"]
        assert @hash.dig("duration", "ms"), "Expected duration to be logged"
        assert_equal 1, @hash["key1"]
        assert_equal "a", @hash["key2"]
        assert payload = @hash["payload"], @hash.inspect
        assert_equal 4, payload["key3"]
      end

      it "includes NewRelic's linking metadata" do
        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          log = SemanticLogger::Log.new("TestLogger", :info)
          SemanticLogger::Logger.call_subscribers(log)
          @appender.log(log)
        end
        parse_logged_message
        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal "Entity Name", @hash["entity.name"]
      end

      it "handles large payloads gracefully" do
        large_payload = {data: "a" * 10_000}
        log = SemanticLogger::Log.new("TestLogger", :info)
        log.payload = large_payload

        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          @appender.log(log)
        end

        parse_logged_message
        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal large_payload[:data], @hash.dig("payload", "data")
      end

      it "handles deeply nested payloads gracefully" do
        nested_payload = {level1: {level2: {level3: {level4: "deep_value"}}}}
        log = SemanticLogger::Log.new("TestLogger", :info)
        log.payload = nested_payload

        NewRelic::Agent.agent.log_event_aggregator.stub(:record, method(:log_newrelic_stub)) do
          @appender.log(log)
        end

        parse_logged_message
        refute_nil @hash, "Expected @hash to be parsed JSON"
        assert_equal "deep_value", @hash.dig("payload", "level1", "level2", "level3", "level4")
      end
    end
  end
end
