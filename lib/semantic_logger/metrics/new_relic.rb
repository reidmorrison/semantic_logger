module SemanticLogger
  module Metrics
    class NewRelic < Subscriber
      attr_accessor :prefix

      # Forward Metrics to NewRelic for dashboarding.
      #
      # Example:
      #   SemanticLogger.on_metric(appender: :new_relic)
      #
      # Parameters:
      #   :prefix [String]
      #     Prefix to add to every metric before forwarding to NewRelic
      #     Default: 'Custom'
      def initialize(prefix: 'Custom')
        @prefix = prefix
      end

      def call(log)
        if duration = log.duration
          # Convert duration to seconds
          ::NewRelic::Agent.record_metric(extract_name(log), duration / 1000.0)
        else
          ::NewRelic::Agent.increment_metric(extract_name(log), log.metric_amount || 1)
        end
      end

      def extract_name(log)
        metric = log.metric
        # Add prefix for NewRelic
        metric = "#{prefix}/#{metric}" unless metric.start_with?(prefix)
        metric
      end

    end
  end
end
