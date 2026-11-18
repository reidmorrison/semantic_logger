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
#     # Name of the queue in RabbitMQ where to publish the logs, through the default exchange.
#     queue_name: 'semantic_logger',
#
#     # This host will be used for RabbitMQ connection.
#     # NOTE this is different than :host option which is used by the logger directly.
#     rabbitmq_host: '127.0.0.1',
#
#     # RabbitMQ credentials
#     username: 'my-username',
#     password: 'my-secret-pass',
#
#     # All other options accepted by Bunny.new call
#     vhost: 'production',
#
#     # Leave out metric-only entries, as v6 does by default:
#     metrics: false
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
      #     Also send metrics only events to rabbitmq.
      #     Default: true, with a deprecation warning when it is not supplied, since v6 changes it to false.
      #
      # RabbitMQ Parameters:
      #
      #   rabbitmq_host: [String]
      #     Host for AMQP connection. in Bunny this is called :host but here it has
      #     been remapped to avoid conflicting with SemanticLogger's :host param.
      #     Default: Bunny's default, 127.0.0.1
      #
      #   username: [String]
      #     Username for AMQP connection
      #     Default: Bunny's default, guest
      #
      #   password: [String]
      #     Password for AMQP connection
      #     Default: Bunny's default, guest
      #
      #   more parameters supported by Bunny: http://rubybunny.info/articles/connecting.html
      def initialize(queue_name: "semantic_logger", rabbitmq_host: nil,
                     level: nil, formatter: nil, filter: nil, application: nil, environment: nil,
                     host: nil, metrics: METRICS_NOT_SUPPLIED, **args, &)
        @queue_name             = queue_name
        @rabbitmq_args          = args.dup
        @rabbitmq_args[:host]   = rabbitmq_host
        @rabbitmq_args[:logger] = logger

        super(level: level, formatter: formatter, filter: filter, application: application,
              environment: environment, host: host, metrics: deprecated_metrics_default(metrics, :rabbitmq), &)
        reopen
      end

      # Connects to RabbitMQ again, with a new channel, and then closes the connection it replaces, with
      # its channel, such as after a log rotation. The next entry is published on the new channel. When
      # connecting fails, it raises, and the appender keeps the connection and channel it has.
      #
      # After a fork, the child first forgets the connection and channel it inherited, without closing
      # them: they belong to the parent. Closing them would send RabbitMQ a channel.close and a
      # connection.close on the parent's connection, which ends it for the parent too, and publishing on
      # the parent's channel would put the child's frames on it, between the parent's. Ruby closes the
      # child's copy of the socket when it collects it, which leaves the parent's open. When connecting
      # fails in the child, the appender has no channel, and connects before it publishes the next entry
      # (see #queue).
      def reopen
        forget_inherited
        replaced = @connection
        connect
        close_replaced(replaced)
      end

      def close
        @queue = nil
        @channel&.close
        @channel = nil
        @connection&.close
        @connection = nil
      end

      def log(log)
        queue.publish(format_log(log))
      end

      def flush
        # NOOP
      end

      # Use JSON Formatter by default.
      def default_formatter
        SemanticLogger::Formatters::Json.new
      end

      # Returns [Bunny::Queue] the queue to publish to, on the appender's channel. Connects first when the
      # appender has no channel: after #close, or when connecting failed as it was reopened after a fork.
      def queue
        @queue ||= (@channel || connect).queue(@queue_name)
      end

      # Only the queue name: the connection options hold the password. See Subscriber#inspect.
      def inspect_details
        "queue_name=#{@queue_name.inspect}"
      end

      private

      # Returns [Bunny::Channel] a new channel, on a new connection to RabbitMQ, after making them the
      # appender's, in place of the connection, channel, and queue it had. Records the process that built
      # them, which owns their connection (see #reopen). When connecting raises, the appender keeps what
      # it had.
      def connect
        connection = Bunny.new(@rabbitmq_args)
        connection.start
        channel     = connection.create_channel
        @connection = connection
        @channel    = channel
        @queue      = nil
        @pid        = ::Process.pid
        channel
      end

      # Closes the connection that a reopen replaced, which closes its channel. Reports an error to the
      # internal logger rather than raising it, since the appender already publishes on the new one.
      def close_replaced(connection)
        connection&.close
      rescue StandardError => e
        logger.warn("Could not close the RabbitMQ connection that a reopen replaced", e)
      end

      # In a child process, forgets the connection and channel built in the parent before a fork, and the
      # queue on that channel. See #reopen.
      def forget_inherited
        return if @pid == ::Process.pid

        @connection = nil
        @channel    = nil
        @queue      = nil
      end
    end
  end
end
