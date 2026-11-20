require "concurrent"
require "semantic_logger/version"
require "semantic_logger/utils"
require "semantic_logger/trap_safe"
require "semantic_logger/ansi_colors"
require "semantic_logger/levels"
require "semantic_logger/ractor_support"
require "semantic_logger/deprecation"
require "semantic_logger/context"
require "semantic_logger/base"
require "semantic_logger/formatters"
require "semantic_logger/exception_details"
require "semantic_logger/backtrace_cleaning"
require "semantic_logger/redactor"
require "semantic_logger/call_site"
require "semantic_logger/log"
require "semantic_logger/subscriber"
require "semantic_logger/loggable"
require "semantic_logger/concerns/compatibility"
require "semantic_logger/appender"
require "semantic_logger/appenders"
require "semantic_logger/queue_processor"
require "semantic_logger/processor"
require "semantic_logger/sync_processor"
require "semantic_logger/logger"
require "semantic_logger/debug_as_trace_logger"
require "semantic_logger/semantic_logger"
require "semantic_logger/metric/collector"

# Logging from Ractors other than the main one (experimental), on Ruby 4.0 and later.
if SemanticLogger::RactorSupport.enabled?
  require "semantic_logger/ractor_copy"
  require "semantic_logger/ractor_receiver"
  require "semantic_logger/ractor_processor"
end

# Automatically reopen appenders in the child process after a fork.
# Enabled by default; opt out with `SemanticLogger.reopen_on_fork = false`.
# Skipped on platforms without `Process._fork` (e.g. JRuby), which cannot fork.
# Loaded on every platform, since it also answers whether this process is a daemon (see
# SemanticLogger::CoreExt::Process.daemon?).
require "semantic_logger/core_ext/process"
Process.singleton_class.prepend(SemanticLogger::CoreExt::Process) if Process.respond_to?(:_fork)

# json 2.8.0 through 3.0.x warn about each binary String they write as UTF-8. Drop that warning
# when it comes from Semantic Logger serializing log data, which it writes the same way with
# json 3.1 (see SemanticLogger::CoreExt::Warning).
Warning.singleton_class.prepend(SemanticLogger::CoreExt::Warning) if SemanticLogger::CoreExt::Warning::NEEDED

# Flush all appenders at exit, waiting for outstanding messages on the queue to be written first.
#
# During an outage of the destination of an appender added with async: true or in batches, that would
# wait while each queued message failed in turn, which can take hours against a server that does not
# answer. So the appenders are first told that the process is exiting, each one directly: the thread
# that writes to every appender can be held up handing a message to that appender's full queue while
# it backs off, and so would hand it the flush only once it stopped backing off. Each one then stops
# backing off and writing again what failed, and once its destination fails a write, discards the
# rest of its queue. An appender without a queue of its own, such as a plain :http, would make that
# thread wait while each message failed in turn instead, so once its destination fails a write, it is
# given no more messages (see SemanticLogger::Appenders#process_exiting=). They are told again once
# the flush has returned, since a test framework can run its tests in a later at_exit hook.
at_exit do
  appenders = SemanticLogger.appenders
  appenders.process_exiting = true
  # Cannot close since test frameworks only run at exit, at which point the logging would already be closed.
  SemanticLogger.flush
ensure
  appenders&.process_exiting = false
end
