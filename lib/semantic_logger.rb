# Include sync_attr dependency
require 'sync_attr'

module SemanticLogger
  autoload :Logger, 'semantic_logger/logger'

  module Appender
    autoload :Logger, 'semantic_logger/appender/logger'
    # Only load the MongoDB appender if the Mongo Ruby Driver is loaded
    autoload :MongoDB, 'semantic_logger/appender/mongodb'
  end
end

if defined?(Rails)
  require 'semantic_logger/railtie'
end
