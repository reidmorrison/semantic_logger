require "concurrent"
require "semantic_logger/version"
require "semantic_logger/utils"
require "semantic_logger/ansi_colors"
require "semantic_logger/levels"
require "semantic_logger/ractor_support"
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

# Logging from Ractors other than the main one (experimental), on Ruby 4.0 and later.
if SemanticLogger::RactorSupport.enabled?
  require "semantic_logger/ractor_copy"
  require "semantic_logger/ractor_receiver"
  require "semantic_logger/ractor_processor"
end

# Automatically reopen appenders in the child process after a fork.
# Enabled by default; opt out with `SemanticLogger.reopen_on_fork = false`.
# Skipped on platforms without `Process._fork` (e.g. JRuby), which cannot fork.
if Process.respond_to?(:_fork)
  require "semantic_logger/core_ext/process"
  Process.singleton_class.prepend(SemanticLogger::CoreExt::Process)
end

# json 2.8.0 through 3.0.x warn about each binary String they write as UTF-8. Drop that warning
# when it comes from Semantic Logger serializing log data, which it writes the same way with
# json 3.1 (see SemanticLogger::CoreExt::Warning).
Warning.extend(SemanticLogger::CoreExt::Warning) if SemanticLogger::CoreExt::Warning::NEEDED

# Flush all appenders at exit, waiting for outstanding messages on the queue
# to be written first.
at_exit do
  # Cannot close since test frameworks only run at exit, at which point the logging would already be closed.
  SemanticLogger.flush
end
