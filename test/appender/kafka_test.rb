require_relative "../test_helper"

module Appender
  class KafkaTest < Minitest::Test
    describe SemanticLogger::Appender::Kafka do
      before do
        @appender = SemanticLogger::Appender::Kafka.new(
          seed_brokers: ["localhost:9092"]
        )
        @message = "AppenderKafkaTest log message"
      end

      after do
        @appender&.close
      end

      it "sends log messages in JSON format" do
        message = nil
        options = nil
        @appender.send(:producer).stub(:produce, ->(value, *opts) { message = value; options = opts.first }) do
          @appender.info(@message)
          @appender.flush
        end

        h = JSON.parse(message)
        assert_equal "info", h["level"]
        assert_equal @message, h["message"]
        assert_equal "SemanticLogger::Appender::Kafka", h["name"]
        assert_equal $$, h["pid"]

        assert_equal "log_messages", options[:topic]
      end
    end
  end
end
