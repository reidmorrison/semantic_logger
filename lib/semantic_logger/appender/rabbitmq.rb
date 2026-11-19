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
      # Seconds to wait for the channel.close that Bunny passes to Channel#on_error, once publishing found the
      # channel closed without a reason: Bunny marks the channel closed before it calls on_error, on a thread
      # of its own.
      CLOSE_REASON_TIMEOUT = 0.1

      # How Bunny::ChannelAlreadyClosed names the channel error that RabbitMQ closed the channel with. Bunny
      # names it for every channel.close but those it passes to Channel#on_error instead.
      CLOSE_REASON_GIVEN = "closed due to a server-reported channel error".freeze

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

      # Publishes the formatted entry. Bunny raises Bunny::ChannelAlreadyClosed or Bunny::ConnectionClosedError
      # before it sends anything, so the entry can be published once more, without publishing it twice, when
      # #restore_publishing can restore what it needs: a new channel, when RabbitMQ has closed the appender's
      # channel while the connection is still open, or a new connection, when Bunny will not recover the one it
      # has. Otherwise, such as while Bunny recovers the connection from a network failure, it raises, and the
      # entry is written again after a back-off.
      def log(log)
        message = format_log(log)
        begin
          had_channel = @channel
          queue.publish(message)
        rescue Bunny::ChannelAlreadyClosed, Bunny::ConnectionClosedError => e
          # Raised while connecting, when the appender had no channel: raised as it is, without connecting
          # again at once, so that the next entry, after any back-off, connects again.
          raise unless had_channel && restore_publishing(e)

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
      # appender has no channel: after #close, when connecting failed as it was reopened after a fork, or once
      # it forgot a connection that Bunny will not recover (see #restore_publishing).
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
        channel, closes = create_channel(connection)
        @connection     = connection
        @channel        = channel
        @channel_closes = closes
        @queue          = nil
        @pid            = ::Process.pid
        channel
      end

      # Returns [Array(Bunny::Channel, Thread::Queue)] a new channel on the given connection, which has
      # started, and the queue that receives the channel.close with which RabbitMQ closes that channel, when
      # Bunny passes it to Channel#on_error, such as for a message larger than its max_message_size. Bunny calls
      # on_error on a thread of its own, after it has marked the channel closed, so the close can arrive after
      # the channel was replaced: each channel has its own queue, so that it is never reported for another.
      #
      # When creating the channel raises, such as Bunny::ClientTimeout from a broker too busy to answer, closes
      # the connection before raising: its reader and heartbeat threads would otherwise keep it open, and
      # recovering, unused.
      def create_channel(connection)
        channel = connection.create_channel
        closes  = Thread::Queue.new
        channel.on_error { |_channel, close| closes << close }
        [channel, closes]
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

      # Returns [true|false] whether the entry that raised the given Bunny::ChannelAlreadyClosed or
      # Bunny::ConnectionClosedError can be published again, on a new channel, or on a new connection.
      #
      # When RabbitMQ has closed the appender's channel while the connection is still open, such as for an
      # entry larger than its max_message_size, which RabbitMQ refuses with PRECONDITION_FAILED by closing the
      # channel, opens a new channel on that connection, and reports the close to the internal logger.
      # RabbitMQ closes the channel after Bunny has published the entry that it refuses, without answering the
      # publish, so that entry was not raised, and cannot be told apart from the others: it is lost (see
      # #report_closed_channel). The entry being published is not at fault, and is published on the new
      # channel.
      #
      # While the connection is not open, leaves it to Bunny, and returns false, when Bunny can still recover
      # it: Bunny closes every channel while it recovers the connection from a network failure, and opens them
      # again once it has reconnected. Otherwise forgets it, so that the entry is published on a new
      # connection (see #forget_abandoned_connection).
      #
      # Bunny marks the connection open again before it reopens its channels, and a closed channel looks the
      # same through Bunny's public API whether RabbitMQ closed it or the network failed, so an entry published
      # in that short gap replaces a channel that Bunny is about to reopen: the appender then reports a close,
      # and the channel it replaced stays open, unused, until the connection is closed. That is left as it is,
      # rather than reaching into Bunny's private channel registry.
      #
      # When opening the channel raises, the connection was closed (see #create_channel), and is forgotten,
      # so that the next entry connects again (see #queue).
      #
      # In a forked child, it forgets the connection and channel it inherited instead, without opening a channel
      # on the parent's connection, and the caller connects again (see #reopen).
      def restore_publishing(error)
        forget_inherited
        return true unless @channel
        return forget_abandoned_connection unless @connection.open?
        # The connection was recovered after publishing raised: the entry is written again after a back-off.
        return false unless error.is_a?(Bunny::ChannelAlreadyClosed)

        closes   = @channel_closes
        @queue   = nil
        @channel = nil
        report_closed_channel(channel_close(closes, error), error)
        open_channel
        true
      end

      # Returns [AMQ::Protocol::Channel::Close|nil] the channel.close that Bunny passed to Channel#on_error for
      # the closed channel whose queue is given, when it is there. Waits up to CLOSE_REASON_TIMEOUT for it only
      # when the given Bunny::ChannelAlreadyClosed does not name a reason: for the closes that Bunny passes to
      # on_error (message_too_large, unknown_delivery_tag, delivery_ack_timeout). For every other channel.close,
      # Bunny names the reason in the error, and calls no on_error. So that wait costs up to 0.1 seconds, on
      # the thread that logs, once per such close, and when the channel was closed without a reason, such as
      # by Channel#close. Bunny marks the channel closed, answers RabbitMQ, and only then records the reason
      # it names in the error, so an entry published during that one write gets an error without the reason:
      # the appender then waits the 0.1 seconds, and reports the close without the reason.
      def channel_close(closes, error)
        return closes.pop(timeout: 0) if error.message.include?(CLOSE_REASON_GIVEN)

        closes.pop(timeout: CLOSE_REASON_TIMEOUT)
      end

      # Reports to the internal logger that RabbitMQ closed the channel, with the channel.close that Bunny
      # passed on (see #create_channel), when it arrived, and otherwise the Bunny::ChannelAlreadyClosed that
      # publishing raised. Only a close for a message larger than RabbitMQ's max_message_size says that an
      # entry was refused.
      def report_closed_channel(close, error)
        if close.respond_to?(:message_too_large?) && close.message_too_large?
          logger.warn("RabbitMQ refused an entry and closed the channel, so that entry was not written, and " \
                      "the next entries are published on a new channel. Reason: #{close.reply_text}")
        else
          logger.warn("RabbitMQ closed the channel, so the entries are published on a new one. " \
                      "Reason: #{close ? close.reply_text : error.message}")
        end
      end

      # Returns [true|false] whether it closed and forgot the appender's connection, which is not open, with
      # its channel and queue, so that the entry is published on a new connection (see #queue). It does so
      # once Bunny will not recover the connection (see #abandoned?), and leaves it to Bunny otherwise.
      def forget_abandoned_connection
        return false unless abandoned?(@connection)

        close_unused(@connection, "that Bunny will not recover")
        @connection = nil
        @channel    = nil
        @queue      = nil
        true
      end

      # Returns [true|false] whether Bunny will not recover the given connection, which is not open, as told
      # through Bunny's public API:
      # - It is closed (Bunny::Session#closed?), such as once Bunny ran out of recovery attempts.
      # - Its status is still :open, its transport being closed (Session#open? is false), and automatic
      #   recovery is off (Session#automatically_recover?): after a network failure, Bunny leaves it so.
      #   A connection.close from RabbitMQ is recovered all the same, unless recover_from_connection_close is
      #   false; Bunny then leaves it so too. When it does recover one, it passes through that state for an
      #   instant first: an entry published in that instant closes the connection, which then stays unused.
      #
      # While Bunny recovers a connection, its status is :disconnected. With automatic recovery on, Bunny only
      # passes through status :open with a closed transport, for an instant before it starts recovering, so
      # that state is not taken as abandoned. The connections that Bunny does not recover in that case, with
      # recover_from_connection_close: false, are left as they are, as are those that keep status
      # :disconnected after an exception that Bunny is configured not to recover from (recoverable_exceptions);
      # the appender connects again once it is reopened (SemanticLogger.reopen). Bunny's flag for
      # recover_from_connection_close is private.
      def abandoned?(connection)
        connection.closed? || (connection.status == :open && !connection.automatically_recover?)
      end

      # Opens a new channel on the appender's connection, which it publishes on next. When that raises, the
      # connection was closed (see #create_channel), and is forgotten.
      def open_channel
        @channel, @channel_closes = create_channel(@connection)
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
