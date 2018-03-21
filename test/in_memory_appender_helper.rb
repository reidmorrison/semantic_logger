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
    {session_id: 'HSSKLEU@JDK767', tracking_number: 12_345}
  end

  let :logger do
    SemanticLogger['TestLogger']
  end

  let :appender_options do
    {appender: appender}
  end

  let :added_appender do
    SemanticLogger.add_appender(appender_options)
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
