module SemanticLogger
  module Metric
    class Otlp < SemanticLogger::Appender::Http
      # Encodes a Metric::Snapshot as the body of an OTLP/HTTP metrics request: an
      # ExportMetricsServiceRequest in the JSON encoding of OTLP (see
      # https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding).
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
      # temporality, since a snapshot holds what was recorded during its interval only. The points of a
      # metric that differ only in their dimensions are data points of one metric.
      module Encoder
        # AggregationTemporality AGGREGATION_TEMPORALITY_DELTA.
        DELTA = 1

        # The instrumentation scope of every metric.
        SCOPE_NAME = "SemanticLogger".freeze

        # The range of an sfixed64 or int64: an Integer outside it is not an intValue or asInt.
        INT64_RANGE = (-(2**63)..((2**63) - 1))

        # How deeply Arrays and Hashes in a dimension value are nested as arrayValue and kvlistValue,
        # beyond which a value is sent as the stringValue of its #inspect.
        MAX_DEPTH = 8

        NANOSECONDS = 1_000_000_000

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

        # Returns [Array<Hash>] a Metric for each kind, name, and unit in the snapshot, with a data
        # point for each of its points. A counter whose sum is not finite has no data point, and a
        # metric left with none is left out.
        def self.metrics(snapshot)
          start_time = nanoseconds(snapshot.start_time)
          end_time   = nanoseconds(snapshot.end_time)
          grouped    = snapshot.points.group_by { |point| [point.kind, point.name, point.unit] }
          grouped.filter_map do |(kind, name, unit), points|
            data_points = points.filter_map { |point| data_point(point, start_time, end_time) }
            next if data_points.empty?

            metric        = {name: text(name)}
            metric[:unit] = text(unit) if unit
            if kind == :counter
              metric[:sum] = {dataPoints: data_points, aggregationTemporality: DELTA, isMonotonic: true}
            else
              metric[:exponentialHistogram] = {dataPoints: data_points, aggregationTemporality: DELTA}
            end
            metric
          end
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

        # Returns [Hash|nil] asInt for an Integer in the range of an sfixed64, otherwise asDouble; nil
        # when the value is not finite.
        def self.number_value(value)
          return {asInt: value.to_s} if value.is_a?(Integer) && INT64_RANGE.cover?(value)

          value = value.to_f
          {asDouble: value} if value.finite?
        end

        # Returns [Hash] the fields of an ExponentialHistogramDataPoint for the histogram, without the
        # sum when it is not finite, min and max when it is empty, and an empty range of buckets.
        def self.histogram(histogram)
          fields = {count: histogram.count.to_s}
          sum    = histogram.sum.to_f
          fields[:sum]       = sum if sum.finite?
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

        # Returns [Array<Hash>] a KeyValue for each key and value of the Hash.
        def self.attributes(hash, depth = 0)
          hash.map { |key, value| {key: text(key), value: any_value(value, depth)} }
        end

        # Returns [Hash] the AnyValue of a Ruby value.
        def self.any_value(value, depth = 0)
          case value
          when true, false
            {boolValue: value}
          when Integer
            INT64_RANGE.cover?(value) ? {intValue: value.to_s} : {stringValue: value.to_s}
          when Float
            {doubleValue: double(value)}
          when Array
            return {stringValue: text(Utils.safe_inspect(value))} if depth >= MAX_DEPTH

            {arrayValue: {values: value.map { |member| any_value(member, depth + 1) }}}
          when Hash
            return {stringValue: text(Utils.safe_inspect(value))} if depth >= MAX_DEPTH

            {kvlistValue: {values: attributes(value, depth + 1)}}
          when nil
            {}
          else
            # A String, a Symbol, or any other object, as its text.
            {stringValue: text(value)}
          end
        end

        # Returns [Float|String] the Float, or how the Protobuf JSON mapping writes one that is not
        # finite, which JSON cannot hold as a number.
        def self.double(value)
          if value.finite? then value
          elsif value.nan? then "NaN"
          elsif value.positive? then "Infinity"
          else
            "-Infinity"
          end
        end

        # Returns [String] decimal nanoseconds since the epoch of a Time, or of a Numeric in seconds.
        def self.nanoseconds(time)
          (time.to_r * NANOSECONDS).to_i.to_s
        end

        # Returns [String] the text of a String, Symbol, or other object, in valid UTF-8.
        def self.text(value)
          value = value.is_a?(Symbol) ? value.name : value.to_s
          Utils.encode_utf8_string(value)
        end

        private_class_method :metrics, :data_point, :number_value, :histogram, :buckets, :attributes, :any_value,
                             :double, :nanoseconds, :text
      end
    end
  end
end
