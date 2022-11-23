# Mocked NewRelic::Agent used for testing

module NewRelic
  module Agent
    module LogEventAggregrator
      def self.record(message, level)
      end
    end

    def self.agent
      self
    end

    def self.log_event_aggregrator
      LogEventAggregrator
    end

    def self.notice_error(message, hash)
    end

    def self.record_metric(name, secoonds)
    end

    def self.increment_metric(name, count = 1)
    end

    def self.linking_metadata
      {"entity.name" => "Entity Name", "entity.type" => "SERVICE", "hostname" => "hostname"}
    end

    module Tracer
      def self.current_trace_id
      end

      def self.current_span_id
      end
    end
  end
end
