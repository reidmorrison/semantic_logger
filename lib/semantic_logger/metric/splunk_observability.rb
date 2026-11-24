module SemanticLogger
  module Metric
    # The metric appender for Splunk Observability Cloud, formerly SignalFx, under its current name, as
    # `add_appender(metric: :splunk_observability)`. It is the same appender as `metric: :signalfx`,
    # which keeps working.
    SplunkObservability = Signalfx
  end
end
