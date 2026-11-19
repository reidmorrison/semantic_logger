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
        close_unused(replaced, "that a reopen replaced")
      end

      # Closes the connection, which closes its channel, and forgets them, and the queue on that channel,
      # even when closing raises, so that the next entry connects again (see #queue). Only the connection
      # is closed: Bunny's Session#close closes each channel that is still open, while Channel#close
      # raises Bunny::ChannelAlreadyClosed for one that RabbitMQ closed, such as after it restarted.
      #
      # In a forked child that has not reopened, such as one that removes the appender before its reopen
      # has run, it forgets the connection and channel it inherited instead, without closing them, since
      # they belong to the parent (see #reopen).
      def close
        forget_inherited
        @connection&.close
      ensure
        @queue      = nil
        @channel    = nil
        @connection = nil
      end

      # Publishes the formatted entry. When RabbitMQ has closed the appender's channel, publishes it on a new
      # channel instead (see #queue). That includes a channel that RabbitMQ closed while this entry was being
      # published: Bunny raises Bunny::ChannelAlreadyClosed before it sends anything, so publishing the entry
      # once more, on the new channel, cannot publish it twice.
      def log(log)
        message = format_log(log)
        begin
          queue.publish(message)
        rescue Bunny::ChannelAlreadyClosed
          queue.publish(message)
        end
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
      # Opens a new channel first when RabbitMQ has closed the appender's channel (see #replace_closed_channel).
      def queue
        replace_closed_channel if @channel&.closed?
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
        channel       = create_channel(connection)
        @connection   = connection
        @channel      = channel
        @queue        = nil
        @close_reason = nil
        @pid          = ::Process.pid
        channel
      end

      # Returns [Bunny::Channel] a new channel on the given connection, which has started. When creating it
      # raises, such as Bunny::ClientTimeout from a broker too busy to answer, closes the connection before
      # raising: its reader and heartbeat threads would otherwise keep it open, and recovering, unused.
      def create_channel(connection)
        channel = connection.create_channel
        channel.on_error { |_channel, close| @close_reason = close.reply_text if channel.equal?(@channel) }
        channel
      rescue StandardError
        close_unused(connection, "whose channel could not be created")
        raise
      end

      # Closes a connection that the appender does not publish on, which closes its channel. Reports an
      # error to the internal logger, with the given description of the connection, rather than raising it:
      # after a reopen, the appender already publishes on the new connection, and when creating a channel
      # failed, that is the error to raise.
      def close_unused(connection, description)
        connection&.close
      rescue StandardError => e
        logger.warn("Could not close the RabbitMQ connection #{description}", e)
      end

      # Opens a new channel on the appender's connection, in place of the one that RabbitMQ closed, such as for
      # an entry larger than its max_message_size, which RabbitMQ refuses with PRECONDITION_FAILED by closing
      # the channel, so that publishing on it raises Bunny::ChannelAlreadyClosed.
      #
      # RabbitMQ closes the channel after Bunny has published the entry that it refuses, without answering the
      # publish, so that entry was not raised, and cannot be told apart from the others: it is lost, and the
      # appender reports to the internal logger that RabbitMQ closed the channel, with the reason when Bunny
      # has passed it on (see #create_channel). The entry being published is not at fault, and is published on
      # the new channel.
      #
      # When opening the channel raises, such as because RabbitMQ has closed the connection too, the connection
      # is closed (see #create_channel) and forgotten, so that the next entry connects again (see #queue).
      #
      # In a forked child, it forgets the connection and channel it inherited instead, without opening a channel
      # on the parent's connection, and the caller connects again (see #reopen).
      def replace_closed_channel
        forget_inherited
        return unless @channel

        reason        = @close_reason
        @close_reason = nil
        @queue        = nil
        @channel      = nil
        logger.warn("RabbitMQ closed the channel, so the entries are published on a new one. " \
                    "An entry that RabbitMQ refused, such as one larger than its max_message_size, " \
                    "was not written. Reason: #{reason || 'not reported'}")
        open_channel
      end

      # Opens a new channel on the appender's connection, which it publishes on next. When that raises, the
      # connection was closed (see #create_channel), and is forgotten.
      def open_channel
        @channel = create_channel(@connection)
      rescue StandardError
        @connection = nil
        raise
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
