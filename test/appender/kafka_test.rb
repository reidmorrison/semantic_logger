require_relative "../test_helper"

module Appender
  class KafkaTest < Minitest::Test
    describe SemanticLogger::Appender::Kafka do
      let(:appender) { SemanticLogger::Appender::Kafka.new(seed_brokers: ["localhost:9092"]) }
      let(:amessage) { "AppenderKafkaTest log message" }

      after do
        appender&.close
      end

      it "sends log messages in JSON format" do
        message = nil
        options = nil
        appender.send(:producer).stub(:produce, lambda { |value, *opts|
          message = value
          options = opts.first
        }) do
          appender.info(amessage)
          appender.flush
        end

        h = JSON.parse(message)
        assert_equal "info", h["level"]
        assert_equal amessage, h["message"]
        assert_equal "SemanticLogger::Appender::Kafka", h["name"]
        assert_equal $$, h["pid"]

        assert_equal "log_messages", options[:topic]
      end
    end
  end
end
