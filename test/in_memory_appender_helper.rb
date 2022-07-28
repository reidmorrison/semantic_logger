require "minitest/shared_description"

InMemoryAppenderHelper = shared_description do
  let :log_message do
    SemanticLogger.flush
    appender.message
  end

  let :log_filter do
    nil
  end

  let :appender do
    InMemoryAppender.new
  end

  let :thread_name do
    Thread.current.name
  end

  let :payload do
    {session_id: "HSSKLEU@JDK767", tracking_number: 12_345, message: "Message from payload"}
  end

  let :logger do
    SemanticLogger::Logger.new("TestLogger", nil, log_filter)
  end

  let :added_appender do
    SemanticLogger.add_appender(appender: appender)
  end

  before do
    SemanticLogger.default_level   = :trace
    SemanticLogger.backtrace_level = :trace
    SemanticLogger.flush
    added_appender
  end

  after do
    SemanticLogger.appenders.each { |appender| SemanticLogger.remove_appender(appender) }
  end
end
