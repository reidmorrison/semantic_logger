require "semantic_logger/core_ext/thread"
require "semantic_logger/version"

# @formatter:off
module SemanticLogger
  autoload :AnsiColors,         "semantic_logger/ansi_colors"
  autoload :Appender,           "semantic_logger/appender"
  autoload :Appenders,          "semantic_logger/appenders"
  autoload :Base,               "semantic_logger/base"
  autoload :DebugAsTraceLogger, "semantic_logger/debug_as_trace_logger"
  autoload :Formatters,         "semantic_logger/formatters"
  autoload :Levels,             "semantic_logger/levels"
  autoload :Log,                "semantic_logger/log"
  autoload :Logger,             "semantic_logger/logger"
  autoload :Loggable,           "semantic_logger/loggable"
  autoload :Processor,          "semantic_logger/processor"
  autoload :Subscriber,         "semantic_logger/subscriber"
  autoload :SyncProcessor,      "semantic_logger/sync_processor"
  autoload :Utils,              "semantic_logger/utils"

  module Concerns
    autoload :Compatibility, "semantic_logger/concerns/compatibility"
  end

  module Metric
    autoload :NewRelic,          "semantic_logger/metric/new_relic"
    autoload :Signalfx,          "semantic_logger/metric/signalfx"
    autoload :Statsd,            "semantic_logger/metric/statsd"
  end

  module Reporters
    autoload :Minitest,          "semantic_logger/reporters/minitest"
  end

  if defined?(JRuby)
    module JRuby
      autoload :GarbageCollectionLogger, "semantic_logger/jruby/garbage_collection_logger"
    end
  end
end
require "semantic_logger/semantic_logger"
# @formatter:on

# Flush all appenders at exit, waiting for outstanding messages on the queue
# to be written first.
at_exit do
  # Cannot close since test frameworks only run at exit, at which point the logging would already be closed.
  SemanticLogger.flush
end
