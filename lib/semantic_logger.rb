# Place requires here to prevent issues on JRuby with global.require.lock=true
require 'thread'
require 'thread_safe'
require 'sync_attr'

module SemanticLogger
  autoload :Base,      'semantic_logger/base'
  autoload :Logger,    'semantic_logger/logger'
  autoload :Loggable,  'semantic_logger/loggable'

  module Appender
    autoload :Base,    'semantic_logger/appender/base'
    autoload :File,    'semantic_logger/appender/file'
    autoload :Wrapper, 'semantic_logger/appender/wrapper'
    autoload :MongoDB, 'semantic_logger/appender/mongodb'
  end

  # Logging levels in order with most detailed logging first
  LEVELS = [:trace, :debug, :info, :warn, :error, :fatal]
end

if defined?(Rails)
  require 'semantic_logger/railtie'
end
