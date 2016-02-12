require 'semantic_logger/core_ext/thread'
require 'semantic_logger/version'
require 'semantic_logger/semantic_logger'

# @formatter:off
module SemanticLogger
  autoload :Base,               'semantic_logger/base'
  autoload :DebugAsTraceLogger, 'semantic_logger/debug_as_trace_logger'
  autoload :Log,                'semantic_logger/log'
  autoload :Logger,             'semantic_logger/logger'
  autoload :Loggable,           'semantic_logger/loggable'

  module Appender
    autoload :Base,             'semantic_logger/appender/base'
    autoload :Bugsnag,          'semantic_logger/appender/bugsnag'
    autoload :Elasticsearch,    'semantic_logger/appender/elasticsearch'
    autoload :File,             'semantic_logger/appender/file'
    autoload :Graylog,          'semantic_logger/appender/graylog'
    autoload :Http,             'semantic_logger/appender/http'
    autoload :MongoDB,          'semantic_logger/appender/mongodb'
    autoload :NewRelic,         'semantic_logger/appender/new_relic'
    autoload :Splunk,           'semantic_logger/appender/splunk'
    autoload :SplunkHttp,       'semantic_logger/appender/splunk_http'
    autoload :Syslog,           'semantic_logger/appender/syslog'
    autoload :Wrapper,          'semantic_logger/appender/wrapper'
  end

  module Metrics
    autoload :NewRelic,         'semantic_logger/metrics/new_relic'
    autoload :Statsd,           'semantic_logger/metrics/statsd'
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
