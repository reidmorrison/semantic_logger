module SemanticLogger
  module Metrics
    class NewRelic
      def call(log_struct)
        metric = log_struct.metric
        # Add 'Custom/' prefix for NewRelic
        metric = "Custom/#{metric}" unless metric.start_with?('Custom')

        if duration = log_struct.duration
          # Convert duration to seconds
          ::NewRelic::Agent.record_metric(metric, duration / 1000.0)
        else
          ::NewRelic::Agent.increment_metric(metric, log.metric_amount || 1)
        end
      end
    end
  end
end
