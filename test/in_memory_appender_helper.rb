require 'minitest/shared_description'

InMemoryAppenderHelper = shared_description do
  let :log_message do
    SemanticLogger.flush
    appender.message
  end

  let :appender do
    InMemoryAppender.new
  end

  let :thread_name do
    Thread.current.name
  end

  let :payload do
    {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
  end

  let :logger do
    SemanticLogger['TestLogger']
  end

  before do
    SemanticLogger.default_level   = :trace
    SemanticLogger.backtrace_level = :trace
    SemanticLogger.add_appender(appender: appender)
  end

  after do
    SemanticLogger.appenders.each { |appender| SemanticLogger.remove_appender(appender) }
  end
end
