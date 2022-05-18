begin
  require "kafka"
rescue LoadError
  raise LoadError, 'Gem ruby-kafka is required for logging to Elasticsearch. Please add the gem "ruby-kafka" to your Gemfile.'
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
#     client_id: "my-application",
#   )
module SemanticLogger
  module Appender
    class Kafka < SemanticLogger::Subscriber
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
      #     Connections can either be a string of "port:protocol" or a full URI with a scheme.
      #     If there's a scheme it's ignored and only host/port are used.
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
      #   ssl_client_cert_key [String]
      #     A PEM encoded client cert key to use with a SSL connection.
      #     Must be used in combination with ssl_client_cert.
      #     Default: nil
      #
      #   ssl_ca_certs_from_system: [boolean]
      #     Delegate SSL CA cert to the system certs
      #
      #    delivery_threshold: [Integer]
      #      Number of messages between triggering a delivery of messages to Apache Kafka.
      #      Default: 100
      #
      #    delivery_interval: [Integer]
      #      Number of seconds between triggering a delivery of messages to Apache Kafka.
      #      Default: 5
      #
      #    required_acks: [Integer]
      #      Number of replicas that must acknowledge receipt of each log message to the topic
      #      Default: 1
      #
      # Semantic Logger Parameters:
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: :raw_json (See: #call)
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
      #     Send metrics only events to kafka.
      #     Default: true
      def initialize(seed_brokers:, client_id: "semantic-logger", connect_timeout: nil, socket_timeout: nil,
                     ssl_ca_cert: nil, ssl_client_cert: nil, ssl_client_cert_key: nil, ssl_ca_certs_from_system: false,
                     topic: "log_messages", partition: nil, partition_key: nil, key: nil,
                     delivery_threshold: 100, delivery_interval: 10, required_acks: 1,
                     metrics: true, **args, &block)

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

        super(metrics: metrics, **args, &block)
        reopen
      end

      def reopen
        @kafka = ::Kafka.new(
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

        @producer = @kafka.async_producer(
          delivery_threshold: delivery_threshold,
          delivery_interval:  delivery_interval,
          required_acks:      required_acks
        )
      end

      def close
        @producer&.shutdown
        @producer = nil
        @kafka&.close
        @kafka = nil
      end

      # Forward log messages to Kafka producer thread.
      def log(log)
        json = formatter.call(log, self)
        @producer.produce(json, topic: topic, partition: partition, partition_key: partition_key, key: key)
      end

      # Use JSON Formatter by default.
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end

      # Restart producer thread since there is no other way to flush.
      def flush
        @producer.shutdown
        @producer = @kafka.async_producer(
          delivery_threshold: delivery_threshold,
          delivery_interval:  delivery_interval
        )
      end

      private

      attr_reader :producer
    end
  end
end
