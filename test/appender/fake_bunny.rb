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

  def start
  end

  def close
  end

  def create_channel
    Channel.new(self)
  end
end
