# Fake class for Bunny (RabbitMQ client)
class FakeBunny
  # AMQ::Protocol::Channel::Close, as passed to the block given to Bunny::Channel#on_error.
  ChannelClose = Struct.new(:reply_code, :reply_text) do
    def message_too_large?
      reply_code == 406 && reply_text.match?(/larger than configured max size/)
    end
  end

  # The reply text of the channel.close with which RabbitMQ refuses a message larger than its max_message_size.
  MESSAGE_TOO_LARGE = "PRECONDITION_FAILED - message size 200 is larger than configured max size 100".freeze

  class Channel
    def initialize(conn)
      @conn   = conn
      @closed = false
    end

    def queue(name)
      raise_if_closed
      Queue.new(name, @conn, self)
    end

    # Bunny::Channel#on_error: the block is called with the channel and the channel.close that RabbitMQ sent
    # it, when that does not answer an operation, such as for a message larger than its max_message_size.
    def on_error(&block)
      @on_error = block
    end

    # Closes the channel as RabbitMQ does when it refuses a message larger than its max_message_size: after
    # the message was published. Like Bunny, marks the channel closed first, and then passes the channel.close
    # to the #on_error block, when it is given one, on a thread of its own, which it returns. That thread
    # waits for an item on the given queue first, when one is given, so that a test can make the close arrive
    # late.
    def close_for_message_too_large(gate = nil)
      @closed = true
      Thread.new do
        gate&.pop
        @on_error&.call(self, ChannelClose.new(406, MESSAGE_TOO_LARGE))
      end
    end

    # Like #close_for_message_too_large, but passes the channel.close on only once a publish on the closed
    # channel has raised, as when Bunny's on_error thread runs after the appender found the channel closed.
    def close_for_message_too_large_after_refused_publish
      gate      = Thread::Queue.new
      @on_raise = -> { gate << true }
      close_for_message_too_large(gate)
    end

    # Closes the channel as RabbitMQ does with a channel error that answers an operation, such as
    # ACCESS_REFUSED: Bunny then names the reason in Bunny::ChannelAlreadyClosed, and calls no on_error.
    def close_with_reason(reply_text)
      @reason = reply_text
      @closed = true
    end

    # Raises Bunny::ChannelAlreadyClosed, as Bunny does for an operation on a closed channel, with the reason
    # when the channel was closed with one (see #close_with_reason).
    def raise_closed
      @on_raise&.call
      message = +"cannot use a closed channel! Channel id: 1"
      message << ", closed due to a server-reported channel error: #{@reason}" if @reason
      raise Bunny::ChannelAlreadyClosed.new(message, self)
    end

    # Marks the channel closed, as Bunny does to every channel of a connection that has failed, while it
    # recovers it (Bunny::Channel#connection_closed!).
    def connection_closed!
      @closed = true
    end

    # Opens the channel again, as Bunny does once it has recovered its connection.
    def recovered!
      @closed = false
    end

    # Closes the channel, as Bunny does, or as RabbitMQ does on a channel error, or when it restarts. Like
    # Bunny::Channel#close, raises once the channel is closed.
    def close
      raise_if_closed
      @closed = true
    end

    def closed?
      @closed
    end

    private

    def raise_if_closed
      raise_closed if @closed
    end
  end

  class Queue
    def initialize(name, conn, channel)
      @name    = name
      @conn    = conn
      @channel = channel
    end

    # Like Bunny::Queue#publish, raises Bunny::ChannelAlreadyClosed, before it publishes anything, once its
    # channel is closed, and otherwise Bunny::ConnectionClosedError while its connection is not open.
    def publish(message)
      @channel.raise_closed if @channel.closed?
      raise Bunny::ConnectionClosedError, "basic.publish" unless @conn.open?

      @conn.published << {message: message, queue: @name}
    end
  end

  attr_accessor :published, :args

  def initialize(args)
    @args      = args
    @published = []
  end

  # Makes #start raise, as Bunny does when it cannot connect to RabbitMQ.
  def refuse_connections
    @refuse_connections = true
    self
  end

  # Makes #create_channel raise once the connection has started, as Bunny does when RabbitMQ does not
  # answer in time, such as when it is overloaded.
  def time_out_channels
    @time_out_channels = true
    self
  end

  # Makes #create_channel raise Bunny::ConnectionClosedError, as Bunny does when RabbitMQ drops the
  # connection between #start and opening the channel.
  def drop_on_channel_open
    @drop_on_channel_open = true
    self
  end

  def start
    raise Bunny::TCPConnectionFailedForAllHosts if @refuse_connections
  end

  def close
    @closed = true
  end

  def closed?
    @closed == true
  end

  # Like Bunny::Session#status: :closed once the connection was closed, :disconnected while it recovers from
  # a network failure (see #lose_network), and otherwise :open, even once its transport was closed.
  def status
    if closed?
      :closed
    elsif @recovering
      :disconnected
    else
      :open
    end
  end

  # Like Bunny::Session#open?, true only while the status is :open and the transport is open.
  def open?
    status == :open && !@transport_closed
  end

  # Like Bunny::Session#automatically_recover?, from the automatically_recover: or automatic_recovery: option,
  # which is true by default.
  def automatically_recover?
    opts = args.first
    return true if opts[:automatically_recover].nil? && opts[:automatic_recovery].nil?

    opts[:automatically_recover] || opts[:automatic_recovery] || false
  end

  # Fails the network. When it recovers automatically, as Bunny sees it before it recovers: the connection is
  # not open, and each of its channels is closed. Otherwise, as Bunny leaves it: the transport is closed, but
  # the status stays :open, and its channels are not closed.
  def lose_network
    return close_transport unless automatically_recover?

    @recovering = true
    channels.each(&:connection_closed!)
    self
  end

  # Closes the transport without recovering it, as Bunny does when RabbitMQ closes the connection and
  # recover_from_connection_close is false: the status stays :open, and the channels are not closed.
  def close_transport
    @transport_closed = true
    self
  end

  # Recovers the connection after #lose_network, as Bunny does, which opens its channels again.
  def recover_network
    @recovering = false
    channels.each(&:recovered!)
    self
  end

  # Gives up recovering the connection after #lose_network, as Bunny does once it has run out of recovery
  # attempts: it closes the connection, and its channels stay closed.
  def give_up_recovery
    @recovering = false
    @closed     = true
    self
  end

  # Returns [FakeBunny::Channel] a new channel, which the connection keeps, as Bunny does.
  def create_channel
    raise Bunny::ClientTimeout if @time_out_channels
    raise Bunny::ConnectionClosedError, "channel.open" if @drop_on_channel_open

    channel = Channel.new(self)
    channels << channel
    channel
  end

  def channels
    @channels ||= []
  end
end
