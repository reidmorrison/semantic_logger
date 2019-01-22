begin
  require 'bunny'
rescue LoadError
  raise 'Gem bunny is required for logging to RabbitMQ. Please add the gem "bunny" to your Gemfile.'
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
      # TODO: doc
      #
      def initialize(queue_name: 'semantic_logger', rabbitmq_host: nil, metrics: true, **args, &block)
        @queue_name = queue_name
        @rabbitmq_args = args.merge(host: rabbitmq_host)

        super(level: level, formatter: formatter, filter: filter, application: application, host: host, metrics: metrics, &block)
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
