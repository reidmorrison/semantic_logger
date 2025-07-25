require "json"

begin
  require "newrelic_rpm"
rescue LoadError
  raise LoadError,
        'Gem newrelic_rpm is required for logging to New Relic. Please add the gem "newrelic_rpm" to your Gemfile.'
end

unless NewRelic::Agent.respond_to?(:linking_metadata)
  raise "NewRelic::Agent.linking_metadata is not defined. Please update newrelic_rpm gem version"
end

unless NewRelic::Agent::Tracer.respond_to?(:current_span_id)
  raise "NewRelic::Agent::Tracer.current_span_id is not defined. Please update newrelic_rpm gem version"
end

unless NewRelic::Agent::Tracer.respond_to?(:current_trace_id)
  raise "NewRelic::Agent::Tracer.current_trace_id is not defined. Please update newrelic_rpm gem version"
end

module SemanticLogger
  module Formatters
    # Formatter for reporting to NewRelic's Logger
    #
    # New Relic gracefully handles (and flattens) any JSON-based logs
    # We construct the JSON and pass it to New Relic for further processing.
    #
    # == Reference
    # * Logging specification
    #   * https://github.com/newrelic/newrelic-exporter-specs/tree/master/logging
    #
    # * Metadata APIs
    #   * https://www.rubydoc.info/gems/newrelic_rpm/NewRelic/Agent#linking_metadata-instance_method
    #   * https://www.rubydoc.info/gems/newrelic_rpm/NewRelic/Agent/Tracer#current_trace_id-class_method
    #   * https://www.rubydoc.info/gems/newrelic_rpm/NewRelic/Agent/Tracer#current_span_id-class_method
    #
    class NewRelicLogs < Raw
      def initialize(**args)
        args.delete(:time_key)
        args.delete(:time_format)

        super(time_key: :timestamp, time_format: :ms, **args)
      end

      def call(log, logger)
        hash = super

        result = {
          **newrelic_metadata,
          message:       hash[:message].to_s,
          tags:          hash[:tags],
          metric:        hash[:metric],
          metric_amount: hash[:metric_amount],
          environment:   hash[:environment],
          application:   hash[:application],
          payload:       hash[:payload],
          timestamp:     hash[:timestamp].to_i,
          logger:        {
            name: log.name
          },
          thread:        {
            name: log.thread_name.to_s
          }
        }.compact

        if hash[:duration_ms] || hash[:duration]
          result[:duration] = {
            ms:    hash[:duration_ms],
            human: hash[:duration]
          }.compact
        end

        if hash[:exception]
          result[:error] = {
            message: hash[:exception][:message],
            class:   hash[:exception][:name],
            stack:   hash[:exception][:stack_trace].join("\n")
          }
        end

        if hash[:file]
          result[:file] = {
            name: hash[:file]
          }
        end

        if hash[:line]
          result[:line] = {
            number: hash[:line].to_s
          }
        end

        # NOTE: Any named tags are merged directly into the result
        # unless there are conflicts with other keys. In that
        # case we clearly log this in the NR log entry so it can
        # be easily alerted on.
        if hash[:named_tags].is_a?(Hash)
          result_keys = result.keys.to_set
          named_tag_conflicts = []

          hash[:named_tags].each do |key, value|
            if result_keys.include?(key)
              named_tag_conflicts << key
            else
              result[key] = value
            end
          end

          result[:named_tag_conflicts] = named_tag_conflicts unless named_tag_conflicts.empty?
        end

        result
      end

      private

      # NOTE: This function will already include trace.id and span.id if they
      # are available so I believe the previous implementation of this is redundant
      # https://rubydoc.info/gems/newrelic_rpm/NewRelic/Agent#linking_metadata-instance_method
      def newrelic_metadata
        NewRelic::Agent.linking_metadata.transform_keys(&:to_sym)
      end
    end
  end
end
