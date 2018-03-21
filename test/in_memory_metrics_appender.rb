# Store in memory the last log message received.
class InMemoryMetricsAppender < SemanticLogger::Subscriber
  attr_accessor :message

  def log(log)
    self.message = log
  end

  # Only forward log entries that contain metrics.
  def should_log?(log)
    log.metric && meets_log_level?(log) && !filtered?(log)
  end
end
