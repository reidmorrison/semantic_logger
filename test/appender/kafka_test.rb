require_relative "../test_helper"
require_relative "../signal_trap_helper"
require "open3"

module Appender
  class KafkaTest < Minitest::Test
    # Stands in for ruby-kafka's clients and producers, recording in #events what a Kafka appender asks of them, such
    # as "producer 1 shut down". They are numbered in the order that they are built.
    class FakeKafka
      attr_reader :events

      # [Thread::Queue] when set, each producer's #shutdown waits for a value from it, or for it to be closed.
      attr_accessor :shutdown_gate

      # [Array<String>] the names of the producers whose #shutdown raises IOError, such as "producer 1".
      attr_reader :failing_shutdowns

      def initialize
        @events            = []
        @built             = Hash.new(0)
        @failing_shutdowns = []
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
        def produce(_value, **)
          kafka.events << "#{name} produced"
        end

        def shutdown
          kafka.shutdown_gate&.pop
          raise(IOError, "#{name} could not shut down") if kafka.failing_shutdowns.include?(name)

          kafka.events << "#{name} shut down"
        end
      end
    end

    # The exit status of a forked child in which the block given to #in_forked_child skipped the test.
    SKIPPED_IN_CHILD = 2

    describe SemanticLogger::Appender::Kafka do
      include SignalTrapHelper

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

      # Returns [String] what the block returned, run in a forked child process. Fails the test with the exception,
      # such as a failed assertion, that the block raised in the child, and skips it when the block skipped it there.
      # Skips the test where fork is not supported.
      def in_forked_child
        skip "fork is not supported" unless Process.respond_to?(:fork)

        reader, writer = IO.pipe
        pid            = fork do
          status = 1
          reader.close
          begin
            writer.write(yield)
            status = 0
          rescue Minitest::Skip => e
            writer.write(e.message)
            status = SKIPPED_IN_CHILD
          rescue StandardError, Minitest::Assertion => e
            writer.write("#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
          end
          writer.close
        ensure
          # Skips the at_exit hooks, such as the one that runs the tests, in the child.
          exit!(status)
        end
        writer.close
        output    = reader.read
        _, status = Process.wait2(pid)
        reader.close

        skip(output) if status.exitstatus == SKIPPED_IN_CHILD

        assert_predicate status, :success?, output
        output
      end

      def new_log
        log         = SemanticLogger::Log.new("Test", :info)
        log.message = amessage
        log
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

        it "keeps the producer of a reopen that runs while it builds a new one, such as in a signal trap" do
          with_fake_kafka do |kafka|
            reopened = false
            kafka.define_singleton_method(:build_producer) do |client|
              unless reopened
                reopened = true
                reopen
              end
              super(client)
            end
            fake_kafka.events.clear
            kafka.flush
            kafka.log(new_log)
            kafka.close
          end

          expected = [
            "client 2 built", "producer 2 built", "producer 3 built", "producer 1 shut down", "client 1 closed",
            "producer 2 produced", "producer 2 shut down", "client 2 closed"
          ]

          assert_equal expected, fake_kafka.events
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
        # A producer that cannot reach Kafka can take a long time to shut down, and the thread that logs writes to
        # every appender.
        it "leaves the producer and client it replaces to a thread that the next log starts, which flush waits for" do
          gate = Thread::Queue.new
          with_fake_kafka do |kafka|
            fake_kafka.events.clear
            kafka.reopen

            assert_equal ["client 2 built", "producer 2 built"], fake_kafka.events

            fake_kafka.events.clear
            fake_kafka.shutdown_gate = gate
            logged = Thread.new { kafka.log(new_log) }

            assert logged.join(5), "#log waited for the producer that the reopen replaced to shut down"
            assert_equal ["producer 2 produced"], fake_kafka.events

            flushed = Thread.new { kafka.flush }

            refute flushed.join(0.2), "#flush did not wait for the producer that the reopen replaced to shut down"

            gate.close

            assert flushed.join(5), "#flush did not return once that producer had shut down"
          end

          expected = [
            "producer 2 produced", "producer 1 shut down", "client 1 closed", "producer 3 built", "producer 2 shut down"
          ]

          assert_equal expected, fake_kafka.events
        ensure
          gate.close
        end

        it "leaves the producers and clients that it replaces for the next flush, oldest first" do
          with_fake_kafka do |kafka|
            kafka.reopen
            kafka.reopen
            fake_kafka.events.clear
            kafka.flush
          end

          expected = [
            "producer 1 shut down", "client 1 closed", "producer 2 shut down", "client 2 closed", "producer 4 built",
            "producer 3 shut down"
          ]

          assert_equal expected, fake_kafka.events
        end

        it "reports an error shutting down a replaced producer on its thread, rather than raising it from each flush" do
          capture = SemanticLogger::Test::CaptureLogEvents.new
          gate    = Thread::Queue.new
          with_fake_kafka do |kafka|
            kafka.logger = capture
            fake_kafka.failing_shutdowns << "producer 1"
            fake_kafka.shutdown_gate = gate
            kafka.reopen
            fake_kafka.events.clear
            kafka.log(new_log)
            gate.close
            kafka.flush
            kafka.flush
            kafka.close
          end

          expected = [
            "producer 2 produced", "client 1 closed", "producer 3 built", "producer 2 shut down", "producer 4 built",
            "producer 3 shut down", "producer 4 shut down", "client 2 closed"
          ]

          assert_equal expected, fake_kafka.events
          assert_equal ["Could not shut down a Kafka producer that a reopen replaced"], capture.events.map(&:message)
          assert_equal([IOError], capture.events.map { |event| event.exception.class })
        ensure
          gate.close
        end

        it "reports an error shutting down a replaced producer on flush, rather than raising it" do
          capture = SemanticLogger::Test::CaptureLogEvents.new
          with_fake_kafka do |kafka|
            kafka.logger = capture
            fake_kafka.failing_shutdowns << "producer 1"
            kafka.reopen
            fake_kafka.events.clear
            kafka.flush
            kafka.close
          end

          expected = [
            "client 1 closed", "producer 3 built", "producer 2 shut down", "producer 3 shut down", "client 2 closed"
          ]

          assert_equal expected, fake_kafka.events
          assert_equal ["Could not shut down a Kafka producer that a reopen replaced"], capture.events.map(&:message)
        end

        it "leaves the producer and client that it replaces for close to shut down and close" do
          with_fake_kafka do |kafka|
            kafka.reopen
            fake_kafka.events.clear
            kafka.close
          end

          expected = ["producer 1 shut down", "client 1 closed", "producer 2 shut down", "client 2 closed"]

          assert_equal expected, fake_kafka.events
        end

        # A real ruby-kafka producer, whose #shutdown locks a Mutex when its threads have not started.
        it "reopens in a signal trap" do
          producer = appender.send(:producer)
          reopened = in_signal_trap do
            appender.reopen
            :reopened
          end

          assert_equal :reopened, reopened
          refute_same producer, appender.send(:producer)
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

        it "leaves the clients and producers that the parent built, even those it replaced, to it after a fork" do
          output = with_fake_kafka do |kafka|
            kafka.reopen
            fake_kafka.events.clear
            in_forked_child do
              kafka.reopen
              kafka.close
              fake_kafka.events.join(",")
            end
          end

          assert_equal "client 3 built,producer 3 built,producer 3 shut down,client 3 closed", output
        end

        it "leaves the clients and producers the parent built to it when closed in a child that has not reopened" do
          output = with_fake_kafka do |kafka|
            kafka.reopen
            fake_kafka.events.clear
            in_forked_child do
              kafka.close
              fake_kafka.events.join(",")
            end
          end

          assert_equal "", output
        end

        it "has no producer after a fork when building one fails, so that logging raises IOError" do
          output = with_fake_kafka do |kafka|
            kafka.delivery_threshold = -1
            in_forked_child do
              errors = []
              [-> { kafka.reopen }, -> { kafka.log(new_log) }].each do |call|
                call.call
              rescue StandardError => e
                errors << "#{e.class}: #{e.message}"
              end
              errors.join("\n")
            end
          end

          expected = [
            "ArgumentError: delivery_threshold: -1",
            "IOError: The Kafka appender has no producer, since it was closed, " \
            "or reopening it after a fork could not build one"
          ]

          assert_equal expected, output.split("\n")
        end

        it "skips the test that forks when the block skips it in the child" do
          skip "fork is not supported" unless Process.respond_to?(:fork)

          error = assert_raises(Minitest::Skip) { in_forked_child { skip "skipped in the child" } }

          assert_equal "skipped in the child", error.message
        end

        it "raises IOError from log after close" do
          with_fake_kafka do |kafka|
            kafka.close

            assert_raises(IOError) { kafka.log(new_log) }
          end
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
