require 'semantic_logger/core_ext/thread'
require 'semantic_logger/version'
require 'semantic_logger/semantic_logger'

# @formatter:off
module SemanticLogger
  autoload :Base,               'semantic_logger/base'
  autoload :Logger,             'semantic_logger/logger'
  autoload :Loggable,           'semantic_logger/loggable'
  autoload :DebugAsTraceLogger, 'semantic_logger/debug_as_trace_logger'

  module Appender
    autoload :Base,     'semantic_logger/appender/base'
    autoload :File,     'semantic_logger/appender/file'
    autoload :Wrapper,  'semantic_logger/appender/wrapper'
    autoload :MongoDB,  'semantic_logger/appender/mongodb'
    autoload :Syslog,   'semantic_logger/appender/syslog'
    autoload :NewRelic, 'semantic_logger/appender/new_relic'
    autoload :Splunk,   'semantic_logger/appender/splunk'
    autoload :Bugsnag,   'semantic_logger/appender/bugsnag'
  end
  # @formatter:on

  if defined?(JRuby)
    module JRuby
      autoload :GarbageCollectionLogger, 'semantic_logger/jruby/garbage_collection_logger'
    end
  end
end

# Flush all appenders at exit, waiting for outstanding messages on the queue
# to be written first
at_exit do
  SemanticLogger.flush
end
