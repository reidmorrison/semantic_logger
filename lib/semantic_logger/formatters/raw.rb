require 'json'
module SemanticLogger
  module Formatters
    class Raw
      # Returns log messages in Hash format
      def call(log, logger)
        log.to_h(logger.host, logger.application)
      end

    end
  end
end

