module SemanticLogger
  module Otlp
    # The OTLP messages that Semantic Logger sends and reads, with the number and type of each of their
    # fields, for Protobuf to write and read their binary encoding. Each is named as in
    # opentelemetry-proto (https://github.com/open-telemetry/opentelemetry-proto, v1 of each package),
    # and each field by its name in the JSON encoding of OTLP, lowerCamelCase, as the Hash that is
    # written holds it. Only the fields that Semantic Logger writes or reads are listed.
    #
    # The types are those of the .proto files, as Symbols, except:
    # - hex_bytes: a bytes field that the JSON encoding of OTLP writes as hex text, rather than base64:
    #   the trace and span ids of a log record;
    # - a Symbol that starts with a capital letter: a message of that name.
    module Schema
      # A field of a message: its number, its type, and whether it is repeated.
      Field = Struct.new(:name, :number, :type, :repeated) do
        # Whether the field holds a message, rather than a scalar.
        def message? = type.match?(/\A[A-Z]/)
      end

      # Returns [Hash<Symbol, Field>] the fields of each message, by the name of the message.
      def self.define(messages)
        messages.to_h do |message, fields|
          definition = fields.to_h do |name, (number, type, repeated)|
            [name, Field.new(name, number, type, repeated == :repeated).freeze]
          end
          [message, definition.freeze]
        end.freeze
      end
      private_class_method :define

      MESSAGES = define(
        # opentelemetry/proto/common/v1/common.proto
        AnyValue:                      {
          stringValue: [1, :string],
          boolValue:   [2, :bool],
          intValue:    [3, :int64],
          doubleValue: [4, :double],
          arrayValue:  [5, :ArrayValue],
          kvlistValue: [6, :KeyValueList],
          bytesValue:  [7, :bytes]
        },
        ArrayValue:                    {values: [1, :AnyValue, :repeated]},
        KeyValueList:                  {values: [1, :KeyValue, :repeated]},
        KeyValue:                      {key: [1, :string], value: [2, :AnyValue]},
        InstrumentationScope:          {
          name:                   [1, :string],
          version:                [2, :string],
          attributes:             [3, :KeyValue, :repeated],
          droppedAttributesCount: [4, :uint32]
        },

        # opentelemetry/proto/resource/v1/resource.proto
        Resource:                      {
          attributes:             [1, :KeyValue, :repeated],
          droppedAttributesCount: [2, :uint32]
        },

        # opentelemetry/proto/metrics/v1/metrics.proto
        ResourceMetrics:               {
          resource:     [1, :Resource],
          scopeMetrics: [2, :ScopeMetrics, :repeated],
          schemaUrl:    [3, :string]
        },
        ScopeMetrics:                  {
          scope:     [1, :InstrumentationScope],
          metrics:   [2, :Metric, :repeated],
          schemaUrl: [3, :string]
        },
        Metric:                        {
          name:                 [1, :string],
          description:          [2, :string],
          unit:                 [3, :string],
          sum:                  [7, :Sum],
          exponentialHistogram: [10, :ExponentialHistogram]
        },
        Sum:                           {
          dataPoints:             [1, :NumberDataPoint, :repeated],
          aggregationTemporality: [2, :enum],
          isMonotonic:            [3, :bool]
        },
        ExponentialHistogram:          {
          dataPoints:             [1, :ExponentialHistogramDataPoint, :repeated],
          aggregationTemporality: [2, :enum]
        },
        NumberDataPoint:               {
          attributes:        [7, :KeyValue, :repeated],
          startTimeUnixNano: [2, :fixed64],
          timeUnixNano:      [3, :fixed64],
          asDouble:          [4, :double],
          asInt:             [6, :sfixed64],
          flags:             [8, :uint32]
        },
        ExponentialHistogramDataPoint: {
          attributes:        [1, :KeyValue, :repeated],
          startTimeUnixNano: [2, :fixed64],
          timeUnixNano:      [3, :fixed64],
          count:             [4, :fixed64],
          sum:               [5, :double],
          scale:             [6, :sint32],
          zeroCount:         [7, :fixed64],
          positive:          [8, :Buckets],
          negative:          [9, :Buckets],
          flags:             [10, :uint32],
          min:               [12, :double],
          max:               [13, :double],
          zeroThreshold:     [14, :double]
        },
        # ExponentialHistogramDataPoint.Buckets
        Buckets:                       {
          offset:       [1, :sint32],
          bucketCounts: [2, :uint64, :repeated]
        },

        # opentelemetry/proto/collector/metrics/v1/metrics_service.proto
        ExportMetricsServiceRequest:   {resourceMetrics: [1, :ResourceMetrics, :repeated]},
        ExportMetricsServiceResponse:  {partialSuccess: [1, :ExportMetricsPartialSuccess]},
        ExportMetricsPartialSuccess:   {rejectedDataPoints: [1, :int64], errorMessage: [2, :string]}
      )

      # Returns [Hash<Symbol, Field>] the fields of the message of that name, raising Protobuf::Error
      # for a message it does not know.
      def self.message(name)
        MESSAGES.fetch(name) { raise(Protobuf::Error, "unknown message #{name.inspect}") }
      end
    end
  end
end
