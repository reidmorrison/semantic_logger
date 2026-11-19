# Fake class for Bunny (RabbitMQ client)
class FakeBunny
  class Channel
    def initialize(conn)
      @conn   = conn
      @closed = false
    end

    def queue(name)
      raise_if_closed
      Queue.new(name, @conn)
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
    def initialize(name, conn)
      @name = name
      @conn = conn
    end

    def publish(message)
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
