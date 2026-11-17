require_relative "../test_helper"
require "open3"

module Appender
  class KafkaTest < Minitest::Test
    # Stands in for ruby-kafka's clients and producers, recording in #events what a Kafka appender asks of them, such
    # as "producer 1 shut down". They are numbered in the order that they are built.
    class FakeKafka
      attr_reader :events

      def initialize
        @events = []
        @built  = Hash.new(0)
      end

      # Returns [Client] a new client, as ::Kafka.new does.
      def client
        Client.new(self, build("client"))
      end

      # Returns [String] the name of a new client or producer, after recording that it was built.
      def build(kind)
        name = "#{kind} #{@built[kind] += 1}"
        events << "#{name} built"
        name
      end

      Client = Struct.new(:kafka, :name) do
        # Raises ArgumentError for a negative delivery_threshold, as ruby-kafka does.
        def async_producer(delivery_threshold:, **)
          raise(ArgumentError, "delivery_threshold: #{delivery_threshold}") if delivery_threshold.negative?

          Producer.new(kafka, kafka.build("producer"))
        end

        def close
          kafka.events << "#{name} closed"
        end
      end

      Producer = Struct.new(:kafka, :name) do
        def shutdown
          kafka.events << "#{name} shut down"
        end
      end
    end

    describe SemanticLogger::Appender::Kafka do
      let(:appender) { SemanticLogger::Appender::Kafka.new(seed_brokers: ["localhost:9092"], metrics: true) }
      let(:amessage) { "AppenderKafkaTest log message" }
      let(:fake_kafka) { FakeKafka.new }

      after do
        appender&.close
      end

      # Yields a Kafka appender whose clients and producers, including those it builds while the block runs, are the
      # stand-ins of fake_kafka.
      def with_fake_kafka
        ::Kafka.stub(:new, ->(**) { fake_kafka.client }) do
          yield(SemanticLogger::Appender::Kafka.new(seed_brokers: ["localhost:9092"], metrics: true))
        end
      end

      describe "metrics:" do
        let(:metric_only) do
          log        = SemanticLogger::Log.new("Test", :info)
          log.metric = "users/signup"
          log
        end

        it "warns that the default changes in v6, and sends metric-only entries, when it is not supplied" do
          line  = __LINE__ + 2
          kafka = assert_deprecated(/kafka_test\.rb:#{line}: warning: SemanticLogger: The :kafka appender sends/) do
            SemanticLogger::Appender::Kafka.new(seed_brokers: ["localhost:9092"])
          end

          assert kafka.should_log?(metric_only)
        ensure
          kafka&.close
        end

        it "leaves metric-only entries out with metrics: false, without a warning" do
          kafka = refute_deprecated do
            SemanticLogger::Appender::Kafka.new(seed_brokers: ["localhost:9092"], metrics: false)
          end

          refute kafka.should_log?(metric_only)
        ensure
          kafka&.close
        end
      end

      # Loads the appender in another Ruby, without RubyGems or the bundle, so that the gem cannot be found, rather than
      # loading it a second time here, which would replace its line coverage.
      it "names Kafka in its error when the ruby-kafka gem is missing" do
        path            = File.expand_path("../../lib/semantic_logger/appender/kafka.rb", __dir__)
        script          = "begin; load(ARGV.fetch(0)); rescue LoadError => e; print(e.message); end"
        message, status = Open3.capture2e(
          {"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby, "--disable-gems", "-e", script, path
        )

        assert_predicate status, :success?, message
        assert_includes message, "ruby-kafka is required for logging to Kafka."
        assert_includes message, 'gem "ruby-kafka"'
      end

      describe "#flush" do
        # Returns [Array<Hash>] the options of each producer that a Kafka appender asks its client for while the block
        # runs, which is given the appender to flush.
        def producer_options(**args)
          client  = ::Kafka.new(["localhost:9092"])
          build   = client.method(:async_producer)
          options = []
          spy     = lambda do |**producer_options|
            options << producer_options
            build.call(**producer_options)
          end
          ::Kafka.stub(:new, client) do
            client.stub(:async_producer, spy) do
              kafka = SemanticLogger::Appender::Kafka.new(seed_brokers: ["localhost:9092"], metrics: true, **args)
              yield(kafka)
            ensure
              kafka&.close
            end
          end
          options
        end

        it "replaces the producer with one built with the options of the first" do
          options  = producer_options(required_acks: 0, delivery_threshold: 7, delivery_interval: 3, &:flush)
          expected = {delivery_threshold: 7, delivery_interval: 3, required_acks: 0}

          assert_equal [expected, expected], options
        end

        it "keeps the default required_acks of 1, rather than ruby-kafka's default of :all" do
          options = producer_options(&:flush)

          assert_equal([1, 1], options.map { |producer| producer[:required_acks] })
        end

        it "shuts down the producer after replacing it" do
          with_fake_kafka do |kafka|
            fake_kafka.events.clear
            kafka.flush
          end

          assert_equal ["producer 2 built", "producer 1 shut down"], fake_kafka.events
        end

        it "keeps its producer, still running, when building a new one fails" do
          with_fake_kafka do |kafka|
            fake_kafka.events.clear
            kafka.delivery_threshold = -1

            assert_raises(ArgumentError) { kafka.flush }
            kafka.close
          end

          assert_equal ["producer 1 shut down", "client 1 closed"], fake_kafka.events
        end

        it "does nothing after #close" do
          with_fake_kafka do |kafka|
            kafka.close
            fake_kafka.events.clear
            kafka.flush
          end

          assert_empty fake_kafka.events
        end
      end

      describe "#reopen" do
        it "shuts down the producer and closes the client that it replaces, after building new ones" do
          with_fake_kafka do |kafka|
            fake_kafka.events.clear
            kafka.reopen
            kafka.close
          end

          expected = [
            "client 2 built", "producer 2 built", "producer 1 shut down", "client 1 closed",
            "producer 2 shut down", "client 2 closed"
          ]

          assert_equal expected, fake_kafka.events
        end

        it "keeps its client and producer when building new ones fails" do
          with_fake_kafka do |kafka|
            fake_kafka.events.clear
            kafka.delivery_threshold = -1

            assert_raises(ArgumentError) { kafka.reopen }
            kafka.close
          end

          assert_equal ["client 2 built", "producer 1 shut down", "client 1 closed"], fake_kafka.events
        end

        it "leaves the client and producer it inherited to the parent process after a fork" do
          skip "fork is not supported" unless Process.respond_to?(:fork)

          reader, writer = IO.pipe
          with_fake_kafka do |kafka|
            fake_kafka.events.clear
            pid = fork do
              reader.close
              kafka.reopen
              kafka.close
              writer.write(fake_kafka.events.join(","))
              writer.close
            ensure
              exit!(0)
            end
            writer.close
            Process.wait(pid)
          end
          output = reader.read
          reader.close

          assert_equal "client 2 built,producer 2 built,producer 2 shut down,client 2 closed", output
        end
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
            SemanticLogger::Appender::Kafka.new(seed_brokers: [seed_broker], metrics: true)
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
