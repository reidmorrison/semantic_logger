begin
  require "kafka"
rescue LoadError
  raise LoadError,
        'Gem ruby-kafka is required for logging to Kafka. Please add the gem "ruby-kafka" to your Gemfile.'
end

require "date"

# Forward all log messages to Apache Kafka.
#
# Example:
#
#   SemanticLogger.add_appender(
#     appender: :kafka,
#
#     # At least one of these nodes must be available:
#     seed_brokers: ["kafka1:9092", "kafka2:9092"],
#
#     # Set an optional client id in order to identify the client to Kafka:
#     client_id: "my-application"
#   )
module SemanticLogger
  module Appender
    class Kafka < SemanticLogger::Subscriber
      SEED_BROKERS_HINT = "Each should be similar to: 'hostname:port' or 'kafka://hostname:port'".freeze
      private_constant :SEED_BROKERS_HINT

      attr_accessor :seed_brokers, :client_id, :connect_timeout, :socket_timeout,
                    :ssl_ca_cert, :ssl_client_cert, :ssl_client_cert_key, :ssl_ca_certs_from_system,
                    :delivery_threshold, :delivery_interval, :required_acks,
                    :topic, :partition, :partition_key, :key

      # Send log messages to Kafka in JSON format.
      #
      # Kafka Parameters:
      #
      #   seed_brokers: [Array<String>, String]
      #     The list of brokers used to initialize the client. Either an Array of connections,
      #     or a comma separated string of connections.
      #     Connections can either be a string of "hostname:port" or a full URI with a scheme.
      #     The scheme must be kafka, kafka+ssl, plaintext, or ssl, or ruby-kafka raises
      #     Kafka::Error. Otherwise only the host and port are used, the port defaulting to 9092.
      #
      #   client_id: [String]
      #     The identifier for this application.
      #     Default: semantic-logger
      #
      #   topic: [String]
      #     Topic to publish log messages to.
      #     Default: 'log_messages'
      #
      #   partition: [Integer]
      #     The partition that the message should be written to.
      #     Default: nil
      #
      #   partition_key: [String]
      #     The key that should be used to assign a partition.
      #     Default: nil
      #
      #   key: [String]
      #     The message key.
      #     Default: nil
      #
      #   connect_timeout: [Integer]
      #     The timeout setting for connecting to brokers.
      #     Default: nil
      #
      #   socket_timeout: [Integer]
      #     The timeout setting for socket connections.
      #     Default: nil
      #
      #   ssl_ca_cert: [String, Array<String>]
      #     A PEM encoded CA cert, or an Array of PEM encoded CA certs, to use with a SSL connection.
      #     Default: nil
      #
      #   ssl_client_cert: [String]
      #     A PEM encoded client cert to use with a SSL connection.
      #     Must be used in combination with ssl_client_cert_key.
      #     Default: nil
      #
      #   ssl_client_cert_key: [String]
      #     A PEM encoded client cert key to use with a SSL connection.
      #     Must be used in combination with ssl_client_cert.
      #     Default: nil
      #
      #   ssl_ca_certs_from_system: [boolean]
      #     Delegate SSL CA cert to the system certs
      #
      #   delivery_threshold: [Integer]
      #     Number of messages between triggering a delivery of messages to Apache Kafka.
      #     Default: 100
      #
      #   delivery_interval: [Integer]
      #     Number of seconds between triggering a delivery of messages to Apache Kafka.
      #     Default: 10
      #
      #   required_acks: [Integer]
      #     Number of replicas that must acknowledge receipt of each log message to the topic
      #     Default: 1
      #
      # Semantic Logger Parameters:
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: none (:trace), so it writes every entry that a logger emits; each logger
      #     filters by its own level.
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: :json
      #
      #   filter: [Regexp|Proc]
      #     RegExp: Only include log messages where the class name matches the supplied.
      #     regular expression. All other messages will be ignored.
      #     Proc: Only include log messages where the supplied Proc returns true
      #           The Proc must return true or false.
      #
      #   host: [String]
      #     Name of this host to appear in log messages.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to appear in log messages.
      #     Default: SemanticLogger.application
      #
      #   metrics: [Boolean]
      #     Also send metric-only entries to kafka.
      #     Default: false
      def initialize(seed_brokers:, client_id: "semantic-logger", connect_timeout: nil, socket_timeout: nil,
                     ssl_ca_cert: nil, ssl_client_cert: nil, ssl_client_cert_key: nil, ssl_ca_certs_from_system: false,
                     topic: "log_messages", partition: nil, partition_key: nil, key: nil,
                     delivery_threshold: 100, delivery_interval: 10, required_acks: 1, **args, &)
        @seed_brokers             = seed_brokers
        @client_id                = client_id
        @connect_timeout          = connect_timeout
        @socket_timeout           = socket_timeout
        @ssl_ca_cert              = ssl_ca_cert
        @ssl_client_cert          = ssl_client_cert
        @ssl_client_cert_key      = ssl_client_cert_key
        @ssl_ca_certs_from_system = ssl_ca_certs_from_system
        @topic                    = topic
        @partition                = partition
        @partition_key            = partition_key
        @key                      = key
        @delivery_threshold       = delivery_threshold
        @delivery_interval        = delivery_interval
        @required_acks            = required_acks
        @retired                  = Thread::Queue.new
        @retiring                 = []
        @generation               = 0

        super(**args, &)
        reopen
      end

      # Replaces the client and its producer with new ones. When building the new ones fails, the
      # appender keeps the client and producer it has.
      #
      # It does not wait for the producer it replaced to deliver the messages it still holds: the next
      # #log starts a thread that shuts that producer down, which delivers them, and closes the client it
      # replaced, and #flush and #close wait for that thread, or shut them down themselves (see
      # #start_retiring and #shut_down_retired). An application can reopen the appender in a signal trap,
      # such as one that reopens the log files after a rotation, where ruby-kafka cannot shut down a
      # producer whose threads have not started, since Ruby does not allow it to lock its Mutex there.
      #
      # It replaces the producer before it hands the old one on, so a #flush on another thread that runs
      # entirely between the two returns before the old producer has delivered the messages it holds:
      # the next #log, #flush, or #close shuts that producer down, which still delivers them.
      #
      # After a fork, the child first forgets the client and producer it inherited, and any that the
      # parent had replaced but not shut down yet, without shutting them down or closing them: they
      # belong to the parent. Shutting a producer down in the child would start its threads again there,
      # and deliver another copy of each message the parent had not delivered yet, over the connections
      # that the parent is still using. Ruby closes the child's copies of those connections when it
      # collects them, which leaves the parent's open. When building the new ones fails in the child, the
      # appender has no producer, and #log raises IOError, until a reopen builds one.
      def reopen
        forget_inherited
        kafka        = build_client
        producer     = build_producer(kafka)
        old_kafka    = @kafka
        old_producer = @producer
        @kafka       = kafka
        @producer    = producer
        @pid         = ::Process.pid
        retire(old_kafka, old_producer)
        @generation += 1
      end

      # Shuts down the producer, which delivers the messages it holds, and closes the client, and those
      # that a reopen replaced, such as when the appender is removed.
      #
      # In a forked child that has not reopened, such as one that removes the appender before its reopen
      # has run, it first forgets the clients and producers it inherited, without shutting them down or
      # closing them, since they belong to the parent (see #reopen).
      def close
        forget_inherited
        shut_down_retired
        @producer&.shutdown
        @producer = nil
        @kafka&.close
        @kafka = nil
      end

      # Forward log messages to Kafka producer thread. Raises IOError when the appender has no producer:
      # after #close, or when a reopen in a forked process could not build one (see #reopen).
      def log(log)
        start_retiring
        producer = @producer || raise(IOError, "The Kafka appender has no producer, since it was closed, " \
                                               "or reopening it after a fork could not build one")
        json     = format_log(log)
        producer.produce(json, topic: topic, partition: partition, partition_key: partition_key, key: key)
      end

      # Use JSON Formatter by default.
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end

      # Shuts down the producer, which waits for it to deliver the messages it holds, since ruby-kafka has
      # no other way to flush one, after replacing it with a new one. When building the new one fails, the
      # appender keeps the producer it has, still running. First shuts down each producer that a reopen
      # replaced, or waits for the thread that shuts it down (see #reopen). Does nothing after #close.
      #
      # A reopen that runs while it builds the new producer, such as in a signal trap, has already
      # replaced the producer, and handed the old one to #shut_down_retired. The flush then drops the
      # producer it built, which has neither threads nor connections, rather than putting it in place of
      # the reopen's, and calls #shut_down_retired again, rather than shutting the old producer down
      # itself, a second time.
      def flush
        shut_down_retired
        return unless @producer

        generation   = @generation
        old_producer = @producer
        producer     = build_producer(@kafka)
        if generation == @generation
          @producer = producer
          old_producer.shutdown
        else
          shut_down_retired
        end
      end

      # Only the topic: the seed brokers can hold credentials, and the options hold the TLS private
      # key and SASL passwords. See Subscriber#inspect.
      def inspect_details
        "topic=#{@topic.inspect}"
      end

      private

      attr_reader :producer

      # Returns [Kafka::Client] a new client with the connection options of this appender. ruby-kafka connects to the
      # brokers only when a producer first delivers messages, so this raises only for invalid options.
      def build_client
        # ruby-kafka puts the seed broker, which can hold credentials, in the error it raises for an
        # invalid one: URI::InvalidURIError, or Kafka::Error for an unknown scheme.
        errors = [URI::InvalidURIError, ::Kafka::Error]
        Utils.without_url_in_errors(option: ":seed_brokers", hint: SEED_BROKERS_HINT, errors: errors) do
          ::Kafka.new(
            seed_brokers:             seed_brokers,
            client_id:                client_id,
            connect_timeout:          connect_timeout,
            socket_timeout:           socket_timeout,
            ssl_ca_cert:              ssl_ca_cert,
            ssl_client_cert:          ssl_client_cert,
            ssl_client_cert_key:      ssl_client_cert_key,
            ssl_ca_certs_from_system: ssl_ca_certs_from_system,
            logger:                   logger
          )
        end
      end

      # Returns [Kafka::AsyncProducer] a producer for the given Kafka client, with the delivery and acknowledgement
      # options of this appender. #reopen and #flush both build their producer here, so that a flush keeps them, rather
      # than leaving out an option, which ruby-kafka then replaces with its own default.
      def build_producer(kafka)
        kafka.async_producer(
          delivery_threshold: delivery_threshold,
          delivery_interval:  delivery_interval,
          required_acks:      required_acks
        )
      end

      # Keeps the client and producer that #reopen replaced for #start_retiring or #shut_down_retired,
      # since #reopen can run in a signal trap. A Thread::Queue, since Ruby allows pushing to one there.
      def retire(kafka, producer)
        @retired << [kafka, producer] if producer
      end

      # Starts a thread for each producer that #reopen replaced, to shut that producer down, which
      # delivers the messages it still holds, and close its client. #log calls it first, rather than
      # shutting them down itself, since it runs on the thread that writes to every appender: while
      # Kafka cannot be reached, shutting a producer down can take half a minute, and once the
      # producer's buffer is full, does not end until Kafka can be reached again, since ruby-kafka
      # retries without a limit. Forgets the threads that have ended.
      #
      # A message that a #log already running gave a replaced producer is delivered too, since the next
      # call starts that producer's shutdown only after it. Since the new producer delivers meanwhile,
      # the messages of a replaced one can reach Kafka after newer ones. Only the thread that writes to
      # the appenders calls #log, #flush, and #close, one at a time, so only that thread uses the list of
      # threads.
      def start_retiring
        return if @retired.empty?

        @retiring.select!(&:alive?)
        while (retired = @retired.pop(timeout: 0))
          @retiring << Thread.new(*retired) do |kafka, producer|
            Thread.current.name = "SL Kafka retire"
            shut_down(kafka, producer)
          end
        end
      end

      # Waits for each thread that #start_retiring started, then shuts down each producer that #reopen
      # replaced since, and closes its client, oldest first. #flush and #close call it first, so that
      # each producer that the appender replaced has delivered the messages it held when they return.
      # Forgets the threads before waiting for them, so that a thread that ended with an exception
      # raises it from one call at most.
      def shut_down_retired
        retiring  = @retiring
        @retiring = []
        retiring.each(&:join)
        while (retired = @retired.pop(timeout: 0))
          shut_down(*retired)
        end
      end

      # Shuts down a producer that #reopen replaced, which delivers the messages it holds, and closes its
      # client, even when the shutdown raises. Reports an error to the internal logger rather than
      # raising it, as ruby-kafka does when it cannot deliver them, so that a producer the appender no
      # longer uses cannot keep #flush or #close from shutting down the one it does use.
      def shut_down(kafka, producer)
        begin
          producer.shutdown
        ensure
          kafka.close
        end
      rescue StandardError => e
        logger.error("Could not shut down a Kafka producer that a reopen replaced", e)
      end

      # In a child process, forgets the client and producer built in the parent before a fork, and those
      # the parent replaced but has not shut down yet. See #reopen.
      def forget_inherited
        return if @pid == ::Process.pid

        @kafka    = nil
        @producer = nil
        @retired  = Thread::Queue.new
        @retiring = []
      end
    end
  end
end
