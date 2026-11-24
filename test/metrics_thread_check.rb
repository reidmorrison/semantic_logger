# Fails a test that leaves metrics being collected once it is over:
# - the thread of a metrics collector, see `SemanticLogger::Metric::Collector`, that the test started, and that has not
#   ended a second after the test's teardown. Such a thread keeps asking the current processor for its metrics
#   interval and giving it snapshots, so that it disturbs later tests, such as one that stubs the processor and expects
#   the snapshots of its own collector only. The check kills it, unless it is the thread of the process's collector,
#   `SemanticLogger::Metric.collector`, whose state later tests rely on.
# - the process's collector collecting, when it was not before the test, such as when the test added a metric appender
#   and did not remove it.
module MetricsThreadCheck
  THREAD_NAME = "SL Metrics".freeze

  def before_setup
    @threads_before_test    = Thread.list
    @collecting_before_test = SemanticLogger::Metric.collector.collecting?
    super
  end

  def after_teardown
    super
    left_metrics_thread
    left_collecting
  end

  private

  def left_metrics_thread
    left = (Thread.list - @threads_before_test).select { |thread| thread.name == THREAD_NAME }
    left.reject! { |thread| thread.join(1) }
    return if left.empty?

    global = SemanticLogger::Metric.collector.thread
    left.each { |thread| thread.kill.join(1) unless thread.equal?(global) }

    flunk("The test left #{left.size} #{THREAD_NAME.inspect} thread(s) running: stop the collectors it started")
  end

  def left_collecting
    return if @collecting_before_test || !SemanticLogger::Metric.collector.collecting?

    flunk("The test left SemanticLogger::Metric.collector collecting: remove the metric appenders it added")
  end
end
Minitest::Test.prepend(MetricsThreadCheck)
