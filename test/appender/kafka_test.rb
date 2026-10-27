require_relative "../test_helper"

module Appender
  class KafkaTest < Minitest::Test
    describe SemanticLogger::Appender::Kafka do
      let(:appender) { SemanticLogger::Appender::Kafka.new(seed_brokers: ["localhost:9092"]) }
      let(:amessage) { "AppenderKafkaTest log message" }

      after do
        appender&.close
      end

      it "does not show the TLS private key or SASL password in #inspect" do
        appender.ssl_client_cert_key = "-----BEGIN PRIVATE KEY-----\nkafka-key\n-----END PRIVATE KEY-----"
        appender.instance_variable_set(:@sasl_plain_password, "kafka-s3cr3t")

        refute_includes appender.inspect, "kafka-key"
        refute_includes appender.inspect, "kafka-s3cr3t"
      end

      it "does not include credentials in the error for a seed broker that cannot be parsed" do
        ["kafka://user:s3cr3t@kafka host:9092", "https://user:s3cr3t@kafka1:9092"].each do |seed_broker|
          error = assert_raises(URI::InvalidURIError, ::Kafka::Error) do
            SemanticLogger::Appender::Kafka.new(seed_brokers: [seed_broker])
          end

          refute_includes error.message, "s3cr3t"
          assert_includes error.message, "Invalid :seed_brokers"
          assert_nil error.cause
        end
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
