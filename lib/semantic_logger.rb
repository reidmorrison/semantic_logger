require 'semantic_logger/core_ext/thread'
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
    autoload :Syslog,  'semantic_logger/appender/syslog'
  end
end
