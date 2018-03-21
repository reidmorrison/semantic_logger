# Store in memory the last log message received.
class InMemoryBatchAppender < SemanticLogger::Subscriber
  attr_accessor :message

  def batch(logs)
    self.message = logs
  end
end
