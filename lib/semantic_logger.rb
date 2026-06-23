require "concurrent"
require "semantic_logger/core_ext/thread"
require "semantic_logger/version"
require "semantic_logger/utils"
require "semantic_logger/ansi_colors"
require "semantic_logger/levels"
require "semantic_logger/base"
require "semantic_logger/formatters"
require "semantic_logger/log"
require "semantic_logger/subscriber"
require "semantic_logger/loggable"
require "semantic_logger/concerns/compatibility"
require "semantic_logger/appender"
require "semantic_logger/appenders"
require "semantic_logger/processor"
require "semantic_logger/sync_processor"
require "semantic_logger/logger"
require "semantic_logger/debug_as_trace_logger"
require "semantic_logger/semantic_logger"

# Automatically reopen appenders in the child process after a fork.
# Enabled by default; opt out with `SemanticLogger.reopen_on_fork = false`.
# Skipped on platforms without `Process._fork` (e.g. JRuby), which cannot fork.
if Process.respond_to?(:_fork)
  require "semantic_logger/core_ext/process"
  Process.singleton_class.prepend(SemanticLogger::CoreExt::Process)
end

# Flush all appenders at exit, waiting for outstanding messages on the queue
# to be written first.
at_exit do
  # Cannot close since test frameworks only run at exit, at which point the logging would already be closed.
  SemanticLogger.flush
end
