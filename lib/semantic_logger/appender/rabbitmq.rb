begin
  require "bunny"
rescue LoadError
  raise LoadError, 'Gem bunny is required for logging to RabbitMQ. Please add the gem "bunny" to your Gemfile.'
end

# Forward all log messages to RabbitMQ.
#
# Example:
#
#   SemanticLogger.add_appender(
#     appender: :rabbitmq,
#
#     # Name of the queue in RabbitMQ where to publish the logs. This queue will be bound to "amqp.direct" exchange.
#     queue: 'semantic_logger',
#
#     # This host will be used for RabbitMQ connection.
#     # NOTE this is different than :host option which is used by the logger directly.
#     rabbitmq_host: '127.0.0.1',
#
#     # RabbitMQ credentials
#     username: 'my-username',
#     password: 'my-secrect-pass',
#
#     # All other options accepted by Bunny.new call
#     vhost: 'production',
#   )
module SemanticLogger
  module Appender
    class Rabbitmq < SemanticLogger::Subscriber
      # Create RabbitMQ appender using Bunny gem
      #
      # Parameters:
      #
      #   queue_name: [String]
      #     Name of RabbitMQ queue where to stream logs to.
      #     This will be a queue bound to AMQP Default exchange
      #     Default: semantic_logger
      #
      #   level: [:trace | :debug | :info | :warn | :error | :fatal]
      #     Override the log level for this appender.
      #     Default: SemanticLogger.default_level
      #
      #   formatter: [Object|Proc|Symbol|Hash]
      #     An instance of a class that implements #call, or a Proc to be used to format
      #     the output from this appender
      #     Default: :json (See: #call)
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
      #     Also send metrics only events to rabbitmq.
      #     Default: true
      #
      # RabbitMQ Parameters:
      #
      #   rabbitmq_host: [String]
      #     Host for AMQP connection. in Bunny this is called :host but here it has
      #     been remapped to avoid conflicting with SemanticLogger's :host param.
      #     Default: localhost
      #
      #   username: [String]
      #     Username for AMQP connection
      #     Default: nil
      #
      #   password: [String]
      #     Password for AMQP connection
      #     Default: nil
      #
      #   more parameters supported by Bunny: http://rubybunny.info/articles/connecting.html
      def initialize(queue_name: "semantic_logger", rabbitmq_host: nil,
                     level: nil, formatter: nil, filter: nil, application: nil, environment: nil, host: nil, metrics: true,
                     **args, &block)
        @queue_name             = queue_name
        @rabbitmq_args          = args.dup
        @rabbitmq_args[:host]   = rabbitmq_host
        @rabbitmq_args[:logger] = logger

        super(level: level, formatter: formatter, filter: filter, application: application, environment: environment, host: host, metrics: metrics, &block)
        reopen
      end

      def reopen
        @connection = Bunny.new(@rabbitmq_args)
        @connection.start
        @channel = @connection.create_channel
      end

      def close
        @channel&.close
        @channel = nil
        @connection&.close
        @connection = nil
      end

      def log(log)
        queue.publish(formatter.call(log, self))
      end

      def flush
        # NOOP
      end

      # Use JSON Formatter by default.
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end

      def queue
        @queue ||= @channel.queue(@queue_name)
      end
    end
  end
end
