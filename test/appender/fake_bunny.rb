# Fake class for Bunny (RabbitMQ client)
class FakeBunny
  # AMQ::Protocol::Channel::Close, as passed to the block given to Bunny::Channel#on_error.
  ChannelClose = Struct.new(:reply_code, :reply_text)

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
    # the message was published, with a channel.close passed to the #on_error block when it is given one.
    def close_for_message_too_large
      @closed = true
      @on_error&.call(self, ChannelClose.new(406, MESSAGE_TOO_LARGE))
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
      raise Bunny::ChannelAlreadyClosed.new("cannot use a closed channel!", self) if @closed
    end
  end

  class Queue
    def initialize(name, conn, channel)
      @name    = name
      @conn    = conn
      @channel = channel
    end

    # Like Bunny::Queue#publish, raises Bunny::ChannelAlreadyClosed, before it publishes anything, once its
    # channel is closed.
    def publish(message)
      raise Bunny::ChannelAlreadyClosed.new("cannot use a closed channel!", @channel) if @channel.closed?

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

  def start
    raise Bunny::TCPConnectionFailedForAllHosts if @refuse_connections
  end

  def close
    @closed = true
  end

  def closed?
    @closed == true
  end

  # Returns [FakeBunny::Channel] a new channel, which the connection keeps, as Bunny does.
  def create_channel
    raise Bunny::ClientTimeout if @time_out_channels

    channel = Channel.new(self)
    channels << channel
    channel
  end

  def channels
    @channels ||= []
  end
end
