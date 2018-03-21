# Store in memory the last log message received.
class InMemoryAppender < SemanticLogger::Subscriber
  attr_accessor :message

  def log(log)
    self.message = log
  end
end
