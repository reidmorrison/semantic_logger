# Store in memory the last log message received.
class MockLogger < SemanticLogger::Subscriber
  attr_accessor :message

  # Format the log message into a raw hash format.
  def log(log)
    self.message = formatter.call(log, self)
  end

  def default_formatter
    SemanticLogger::Formatters::Raw.new
  end
end

