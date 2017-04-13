require 'semantic_logger/core_ext/thread'
require 'semantic_logger/version'
require 'semantic_logger/semantic_logger'

# @formatter:off
module SemanticLogger
  autoload :AnsiColors,         'semantic_logger/ansi_colors'
  autoload :Appender,           'semantic_logger/appender'
  autoload :Base,               'semantic_logger/base'
  autoload :DebugAsTraceLogger, 'semantic_logger/debug_as_trace_logger'
  autoload :Log,                'semantic_logger/log'
  autoload :Logger,             'semantic_logger/logger'
  autoload :Loggable,           'semantic_logger/loggable'
  autoload :Processor,          'semantic_logger/processor'
  autoload :Subscriber,         'semantic_logger/subscriber'

  module Concerns
    autoload :Compatibility,    'semantic_logger/concerns/compatibility'
  end

  module Formatters
    autoload :Base,             'semantic_logger/formatters/base'
    autoload :Color,            'semantic_logger/formatters/color'
    autoload :Default,          'semantic_logger/formatters/default'
    autoload :Json,             'semantic_logger/formatters/json'
    autoload :Raw,              'semantic_logger/formatters/raw'
    autoload :Syslog,           'semantic_logger/formatters/syslog'
  end

  module Metrics
    autoload :NewRelic,         'semantic_logger/metrics/new_relic'
    autoload :Statsd,           'semantic_logger/metrics/statsd'
    autoload :Udp,              'semantic_logger/metrics/udp'
  end

  if defined?(JRuby)
    module JRuby
      autoload :GarbageCollectionLogger, 'semantic_logger/jruby/garbage_collection_logger'
    end
  end
end
# @formatter:on

# Close and flush all appenders at exit, waiting for outstanding messages on the queue
# to be written first
at_exit do
  SemanticLogger.close
end
