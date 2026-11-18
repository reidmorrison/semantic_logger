# Fake class for Bunny (RabbitMQ client)
class FakeBunny
  class Channel
    def initialize(conn)
      @conn = conn
    end

    def queue(name)
      Queue.new(name, @conn)
    end

    def close
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

  def start
    raise Bunny::TCPConnectionFailedForAllHosts if @refuse_connections
  end

  def close
    @closed = true
  end

  def closed?
    @closed == true
  end

  def create_channel
    Channel.new(self)
  end
end
