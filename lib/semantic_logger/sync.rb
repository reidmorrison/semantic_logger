# Run Semantic Logger in Synchronous mode.
#
# I.e. Instead of logging messages in a separate thread for better performance,
# log them using the current thread.
#
# Usage:
#   require "semantic_logger/sync"
#
# Or, when using a Gemfile:
#   gem "semantic_logger", require: "semantic_logger/sync"
require "semantic_logger"
SemanticLogger.sync!
