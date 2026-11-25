module SemanticLogger
  module Otlp
    # The resource of OTLP data: the attributes that say which process sent it, such as its service,
    # host, and environment, from the values given, the OpenTelemetry environment variables, and
    # Semantic Logger's own settings, and the `process.pid` of the process that writes each request.
    #
    # It knows which of these wins over which, and which attribute each one is. Whoever writes OTLP data,
    # such as Exporter, or Formatters::OtlpJsonLines, decides which values it was given.
    class Resource
      # The attribute that holds the pid of the process that writes each request.
      PID_ATTRIBUTE = "process.pid".freeze

      # The attribute of each value that may be given or defaulted.
      NAMES = {
        application: "service.name",
        host:        "host.name",
        environment: "deployment.environment.name"
      }.freeze

      # Returns [Hash<String, Object>] the attributes of the resource, other than `process.pid`, which is
      # that of the process that writes each request, unless `attributes:` gave one (see
      # #process_attributes).
      attr_reader :attributes

      # Parameters:
      #   otel: [Otlp::Environment]
      #     The OpenTelemetry environment variables, of which it reads OTEL_RESOURCE_ATTRIBUTES and
      #     OTEL_SERVICE_NAME.
      #
      #   defaults: [Hash]
      #     The `application:`, `host:`, and `environment:` to use when neither they are given, nor set in
      #     the environment, such as SemanticLogger.application, .host, and .environment.
      #
      #   given: [Hash]
      #     The `application:`, `host:`, and `environment:` given, which win over the environment's.
      #     An `application:` that is nil takes OTEL_SERVICE_NAME.
      #
      #   attributes: [Hash|nil]
      #     More attributes, which replace all of the above with the same key.
      #
      #   logger: [SemanticLogger::Logger]
      #     Warns about a `process.pid` in OTEL_RESOURCE_ATTRIBUTES, which it leaves out.
      #
      # Highest first: `attributes:`; `given:`, and OTEL_SERVICE_NAME; OTEL_RESOURCE_ATTRIBUTES; then
      # `defaults:`. The environment has no deployment environment when none is given or defaulted.
      def initialize(otel:, defaults:, given: {}, attributes: nil, logger: nil)
        given          = given.merge(application: given[:application] || otel.service_name)
        from_env       = otel.resource_attributes
        resource       = named(defaults)
        if from_env.key?(PID_ATTRIBUTE)
          logger&.warn("Ignoring #{PID_ATTRIBUTE} in OTEL_RESOURCE_ATTRIBUTES: each process sends its own")
        end
        resource.merge!(from_env.except(PID_ATTRIBUTE))
        resource.merge!(named(given))
        attributes&.each { |key, value| resource[key.to_s] = value }
        @attributes = resource.freeze
      end

      # Returns [Hash<String, Object>] the attributes of the resource of a request: #attributes, with the
      # `process.pid` of the process that writes it, unless `attributes:` gave one, so that the data of
      # each process, such as forked workers of the same application on the same host, are kept apart.
      # Since every process of a deployment shares its environment, OTEL_RESOURCE_ATTRIBUTES cannot.
      def process_attributes
        attributes.merge(PID_ATTRIBUTE => ::Process.pid) { |_key, given, _pid| given }
      end

      private

      # Returns [Hash<String, Object>] the attributes of the values that are not nil, by their names.
      def named(values)
        NAMES.each_with_object({}) do |(key, name), named|
          value       = values[key]
          named[name] = value unless value.nil?
        end
      end
    end
  end
end
