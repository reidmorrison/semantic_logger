require "json"
module SemanticLogger
  module Formatters
    class OpenTelemetry < Raw
      # Remove the following fields since they are sent via the OpenTelemetry API
      def time
      end

      # Log level
      def level
      end

      # Payload is submitted directly as attributes
      def payload
      end
    end
  end
end
