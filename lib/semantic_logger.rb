# Place requires here to prevent issues on JRuby with global.require.lock=true
require 'thread'
require 'semantic_logger/version'
require 'semantic_logger/semantic_logger'

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
end
