module SemanticLogger
  module Metric
    class Otlp < SemanticLogger::Appender::Http
      # Encodes a Metric::Snapshot as the body of an OTLP/HTTP metrics request: an
      # ExportMetricsServiceRequest, built as the Hash of its JSON encoding (see
      # https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding), which
      # SemanticLogger::Otlp::Protocol writes as JSON, or in the binary Protobuf encoding, from the
      # same Hash (see SemanticLogger::Otlp::Protobuf).
      #
      # It knows that mapping and nothing about where the request is sent: the appender gives it the
      # attributes of the resource.
      #
      # The JSON encoding of OTLP is the standard Protobuf JSON mapping, with these rules:
      # - field names are lowerCamelCase;
      # - enums, such as the aggregation temporality, are integers;
      # - 64-bit integers (timestamps, counts, an Integer counter sum, an Integer attribute) are
      #   decimal Strings;
      # - a field that holds its default value, such as an empty list, may be left out, as it is here.
      #
      # Each counter is a monotonic Sum and each histogram an ExponentialHistogram, both with delta
      # temporality, since a snapshot holds what was recorded during its interval only. The points of
      # one kind, name, and unit, either all Semantic Logger's own or all an application's, are the
      # data points of one metric, which is what identifies a metric in OpenTelemetry. The Aggregator
      # keeps one kind and one unit per name in an interval, and Semantic Logger's own metrics have
      # names of their own (semantic_logger.*), so a snapshot that it collected has one metric per
      # name. A merged snapshot, holding the points of more than one interval, may hold one name with
      # two units or kinds, and one built otherwise may hold both Semantic Logger's own points and an
      # application's of one name: each is then a metric of its own, of the same name, rather than one
      # being left out (see .metrics).
      module Encoder
        # AggregationTemporality AGGREGATION_TEMPORALITY_DELTA.
        DELTA = 1

        # The instrumentation scope of every metric.
        SCOPE_NAME = "SemanticLogger".freeze

        # The range of an sfixed64 or int64: an Integer outside it is not an intValue or asInt.
        INT64_RANGE = SemanticLogger::Otlp::Values::INT64_RANGE

        # Returns [String] the JSON of the request for the snapshot.
        #
        # resource: [Hash] attributes of the resource that sends the metrics, such as "service.name".
        def self.call(snapshot, resource)
          JSON.generate(request(snapshot, resource))
        end

        # Returns [Hash] the ExportMetricsServiceRequest for the snapshot.
        def self.request(snapshot, resource)
          {
            resourceMetrics: [
              {
                resource:     {attributes: attributes(resource)},
                scopeMetrics: [
                  {
                    scope:   {name: SCOPE_NAME, version: SemanticLogger::VERSION},
                    metrics: metrics(snapshot)
                  }
                ]
              }
            ]
          }
        end

        # Returns [Array<Hash>] a Metric for each kind, name, and unit in the snapshot, apart for
        # Semantic Logger's own points and an application's, with a data point for each of its points.
        # A counter whose sum is not finite has no data point, and a metric left with none is left out.
        def self.metrics(snapshot)
          start_time = nanoseconds(snapshot.start_time)
          end_time   = nanoseconds(snapshot.end_time)
          groups     = snapshot.points.group_by do |point|
            [point.internal?, point.kind, text(point.name), point.unit && text(point.unit)]
          end
          groups.filter_map do |(_internal, _kind, name, _unit), points|
            data_points = points.filter_map { |point| data_point(point, start_time, end_time) }
            next if data_points.empty?

            metric(name, points.first, data_points)
          end
        end

        # Returns [Hash] the Metric of the name, of the kind and unit of the point, with the data points.
        def self.metric(name, point, data_points)
          metric        = {name: name}
          metric[:unit] = text(point.unit) if point.unit
          if point.counter?
            metric[:sum] = {dataPoints: data_points, aggregationTemporality: DELTA, isMonotonic: true}
          else
            metric[:exponentialHistogram] = {dataPoints: data_points, aggregationTemporality: DELTA}
          end
          metric
        end

        # Returns [Hash|nil] the NumberDataPoint of a counter, or the ExponentialHistogramDataPoint of a
        # histogram; nil for a counter whose sum is not finite.
        def self.data_point(point, start_time, end_time)
          data_point = {startTimeUnixNano: start_time, timeUnixNano: end_time}
          data_point[:attributes] = attributes(point.dimensions) unless point.dimensions.empty?
          if point.counter?
            value = number_value(point.value)
            value && data_point.merge!(value)
          else
            data_point.merge!(histogram(point.value))
          end
        end

        # Returns [Hash|nil] asInt for an Integer in the range of an sfixed64, otherwise asDouble, such
        # as for the exact Integer sum of a counter that has grown beyond 64 bits; nil when the value
        # is not finite as a Float, such as an Integer beyond Float::MAX.
        def self.number_value(value)
          return {asInt: value.to_s} if value.is_a?(Integer) && INT64_RANGE.cover?(value)

          value = value.to_f
          {asDouble: value} if value.finite?
        end

        # Returns [Hash] the fields of an ExponentialHistogramDataPoint for the histogram, without the
        # sum when it is not finite, or when a negative value was recorded, since OTLP takes the sum as
        # that of non-negative events, which only grows (a Prometheus `_sum` counter, for one), without
        # min and max when it is empty, and without an empty range of buckets.
        def self.histogram(histogram)
          fields = {count: histogram.count.to_s}
          sum    = histogram.sum.to_f
          fields[:sum]       = sum if sum.finite? && !histogram.min&.negative?
          fields[:scale]     = histogram.scale
          fields[:zeroCount] = histogram.zero_count.to_s
          fields[:positive]  = buckets(histogram.positive) unless histogram.positive.empty?
          fields[:negative]  = buckets(histogram.negative) unless histogram.negative.empty?
          fields[:min]       = histogram.min.to_f unless histogram.min.nil?
          fields[:max]       = histogram.max.to_f unless histogram.max.nil?
          fields
        end

        def self.buckets(buckets)
          {offset: buckets.offset, bucketCounts: buckets.counts.map(&:to_s)}
        end

        # Returns [Array<Hash>] a KeyValue for each key and value of the dimensions.
        def self.attributes(hash)
          hash.map { |key, value| {key: text(key), value: any_value(value)} }
        end

        # Returns [Hash] the AnyValue of a dimension value, or of a member of an Array, as the Aggregator
        # leaves them (see Aggregator.normalize_dimensions): a String, Integer, Float, true, false, nil,
        # or an Array of them. An Integer beyond 64 bits is sent as its text. Anything else, in a
        # snapshot built otherwise, is sent as its text too: a Hash, or an Array within an Array, as its
        # #inspect; and a Float that is not finite as the Protobuf JSON mapping writes it.
        def self.any_value(value, member: false)
          case value
          when true, false
            {boolValue: value}
          when Integer
            INT64_RANGE.cover?(value) ? {intValue: value.to_s} : {stringValue: value.to_s}
          when Float
            {doubleValue: double(value)}
          when nil
            {}
          when Array
            return {stringValue: text(Utils.safe_inspect(value))} if member

            {arrayValue: {values: value.map { |item| any_value(item, member: true) }}}
          when Hash
            {stringValue: text(Utils.safe_inspect(value))}
          else
            # A String, a Symbol, or any other object, as its text.
            {stringValue: text(value)}
          end
        end

        # See SemanticLogger::Otlp::Values.
        def self.double(value) = SemanticLogger::Otlp::Values.double(value)

        def self.nanoseconds(time) = SemanticLogger::Otlp::Values.nanoseconds(time)

        def self.text(value) = SemanticLogger::Otlp::Values.text(value)

        private_class_method :metrics, :metric, :data_point, :number_value, :histogram, :buckets,
                             :attributes, :any_value, :double, :nanoseconds, :text
      end
    end
  end
end
