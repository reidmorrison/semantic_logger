# Forward application metrics to SignalFx (Splunk Observability Cloud).
#
# Example:
#   SemanticLogger.add_appender(
#     metric: :signalfx,
#     token:  'SIGNALFX_ORG_ACCESS_TOKEN'
#   )
module SemanticLogger
  module Metric
    # A metric appender (see Metric::Snapshots): once per interval it posts the snapshot of the metrics
    # recorded, as datapoints, to the SignalFx ingest API (`v2/datapoint`), in one request.
    #
    # Each counter series is sent as a `counter` datapoint holding what was added to it in the interval.
    #
    # SignalFx takes no exponential histograms in this API, so each histogram series is sent as:
    #   <name>        gauge    the mean
    #   <name>.count  counter  the number of values recorded in the interval
    #   <name>.sum    counter  their sum
    #   <name>.min    gauge    the smallest
    #   <name>.max    gauge    the largest
    #   <name>.p50    gauge    the median, estimated from the histogram
    #   <name>.p95    gauge    the 95th percentile, estimated
    #   <name>.p99    gauge    the 99th percentile, estimated
    # A histogram of durations, in seconds (unit "s"), such as from `logger.time` or `measure_*`, is sent
    # in milliseconds, as Semantic Logger 5 sent a duration, so that existing charts keep their scale.
    #
    # A "/" in a name becomes a ".", and a leading "/" is left out. Each datapoint has the dimensions of
    # its series, with each value as text, leaving out those whose value is blank (nil, or text that is
    # empty or only whitespace), and the `host`, `application`, and, when it is set, `environment` of the
    # appender.
    #
    # A series whose name holds a "/", and that has no dimensions (or only blank ones), is sent as
    # Semantic Logger 5 sent such a metric, so that existing charts keep working: the class and action
    # are taken from its name, as the dimensions `class` and `action`, and the metric is named
    # "Application". For example a counter "Common/User/authorize" is sent as the counter
    # "Application.counter", with the dimensions `class: "Common::User", action: "authorize"`; a histogram
    # of that name as "Application.counter" (the count), "Application.average" (the mean), and
    # "Application.sum", "Application.min", ... "Application.p99".
    class Signalfx < SemanticLogger::Appender::Http
      include Snapshots

      attr_reader :full_path

      END_POINT = "v2/datapoint".freeze

      # The name of the metric that a series named as "Class/action", without dimensions, is sent as.
      CLASS_ACTION_METRIC = "Application".freeze

      # The quantiles sent for each histogram, by the suffix of their names.
      QUANTILES = {"p50" => 0.5, "p95" => 0.95, "p99" => 0.99}.freeze

      # Text of a dimension value that is blank (see #blank_value?).
      BLANK_VALUE = /\A[[:space:]]*\z/
      private_constant :BLANK_VALUE

      # The body of one request: the `counter` and `gauge` datapoints of a snapshot, each stamped with the
      # end of its interval, in milliseconds. Counters with the same name and dimensions, such as a
      # counter and the count of a histogram both named "Class/action", are added together.
      class Datapoints
        def initialize(time)
          @timestamp = (time.to_r * 1000).to_i
          @counters  = {}
          @gauges    = []
        end

        def counter(metric, value, dimensions)
          existing = @counters[[metric, dimensions]]
          if existing
            existing[:value] += value
          else
            @counters[[metric, dimensions]] = datapoint(metric, value, dimensions)
          end
        end

        def gauge(metric, value, dimensions)
          @gauges << datapoint(metric, value, dimensions)
        end

        # Returns [Hash] the datapoints by type, leaving out a type without any.
        def to_h
          data           = {}
          data[:counter] = @counters.values unless @counters.empty?
          data[:gauge]   = @gauges unless @gauges.empty?
          data
        end

        private

        def datapoint(metric, value, dimensions)
          {metric: metric, value: value, dimensions: dimensions, timestamp: @timestamp}
        end
      end
      private_constant :Datapoints

      # Create SignalFx metrics appender.
      #
      # Parameters:
      #   token: [String]
      #     Access Token to use for sending metrics.
      #     Obtain the Signalfx token via the Signalfx Web UI under `Organization` -> `Access Tokens`.
      #
      #   interval: [Numeric]
      #     Seconds between the requests it sends, each holding the metrics of that interval.
      #     Default: 60
      #
      #   internal_metrics: [true|false]
      #     Whether to send Semantic Logger's own metrics too.
      #     Default: false
      #
      #   host: [String]
      #     Name of this host to send as a dimension.
      #     Default: SemanticLogger.host
      #
      #   application: [String]
      #     Name of this application to send as a dimension.
      #     Default: SemanticLogger.application
      #
      #   environment: [String]
      #     Name of this environment to send as a dimension, when set.
      #     Default: SemanticLogger.environment
      #
      #   url: [String]
      #     Override the SignalFx service url. The metrics are posted to `v2/datapoint` under its path.
      #     Default: https://ingest.signalfx.com
      #
      # The `dimensions:` option of Semantic Logger 5, which listed the named tags to send as dimensions,
      # raises ArgumentError: the named tags are never part of a metric's series. Give the dimensions to
      # the metric call instead, such as `logger.increment("filters", dimensions: {plan: "premium"})`.
      def initialize(token:, url: "https://ingest.signalfx.com", dimensions: nil, **args, &)
        if dimensions
          raise(ArgumentError,
                "The dimensions: option of the :signalfx metric appender was removed in v6, since the named " \
                "tags are never part of a metric's series. Give the dimensions to the metric call instead, " \
                "such as logger.increment(name, dimensions: {...}).")
        end

        super(url: url, **args, &)

        replace_header("X-SF-TOKEN", token)
        # Built from the parsed path, not the supplied url, so that a query string in the
        # url stays at the end of the request uri. See Appender::Http#uri_with_query.
        @full_path = "#{@path.end_with?('/') ? @path : "#{@path}/"}#{END_POINT}"
      end

      # Posts the datapoints of the snapshot in one request. Raises Appender::Http::ResponseError when the
      # server does not accept it.
      def write_metrics(snapshot)
        body = Utils.to_json(datapoints(snapshot))
        logger.trace(body)
        post(body, full_path)
      end

      private

      # Returns [Hash] the body of the request for the snapshot (see Datapoints).
      def datapoints(snapshot)
        datapoints = Datapoints.new(snapshot.end_time)
        snapshot.each do |point|
          name, dimensions, class_action = series(point)
          if point.counter?
            datapoints.counter(class_action ? "#{name}.counter" : name, point.value, dimensions)
          else
            add_histogram(datapoints, point, name, dimensions, class_action)
          end
        end
        datapoints.to_h
      end

      # Returns [Array] the name to send the point under, its dimensions, and whether the name is
      # CLASS_ACTION_METRIC, with the class and action taken from the point's name.
      def series(point)
        name       = Utils.encode_utf8_string(point.name.to_s)
        stripped   = name.sub(%r{\A/+}, "")
        name       = stripped unless stripped.empty?
        dimensions = present_dimensions(point.dimensions)
        names      = name.split("/")
        if dimensions.empty? && names.size > 1
          action     = names.pop
          dimensions = {"class" => names.join("::"), "action" => action}
          [CLASS_ACTION_METRIC, add_default_dimensions(dimensions), true]
        else
          [name.tr("/", "."), add_default_dimensions(dimensions), false]
        end
      end

      # Adds the count, sum, mean, min, max, and quantiles of the histogram of the point, in milliseconds
      # for one of durations in seconds.
      def add_histogram(datapoints, point, name, dimensions, class_action)
        histogram = point.value
        return if histogram.empty?

        scale = point.unit == "s" ? 1000 : 1
        datapoints.counter(class_action ? "#{name}.counter" : "#{name}.count", histogram.count, dimensions)
        datapoints.counter("#{name}.sum", histogram.sum * scale, dimensions)
        datapoints.gauge(class_action ? "#{name}.average" : name, histogram.sum * scale / histogram.count, dimensions)
        datapoints.gauge("#{name}.min", histogram.min * scale, dimensions)
        datapoints.gauge("#{name}.max", histogram.max * scale, dimensions)
        QUANTILES.each_pair do |suffix, probability|
          datapoints.gauge("#{name}.#{suffix}", histogram.quantile(probability) * scale, dimensions)
        end
      end

      # Returns [Hash] the dimensions with each name and value as text, leaving out those that are blank.
      def present_dimensions(dimensions)
        present = {}
        dimensions.each_pair do |key, value|
          value             = value.to_s
          present[key.to_s] = value unless blank_value?(value)
        end
        present
      end

      # Adds the host, application, and, when set, environment of the appender to the dimensions.
      def add_default_dimensions(dimensions)
        dimensions["host"]        = host if host
        dimensions["application"] = application if application
        dimensions["environment"] = environment if environment
        dimensions
      end

      # Returns [true|false] whether the text of a dimension value is blank: empty, as for nil, or only
      # whitespace, which includes Unicode whitespace such as a no-break space, but not NUL. The text is
      # converted to valid UTF-8 first (see Utils.encode_utf8_string): matching raises for UTF-8 text
      # with invalid bytes, or text that is not ASCII-compatible, such as UTF-16, and would not find the
      # Unicode whitespace in text in an encoding such as binary or Shift_JIS.
      def blank_value?(text) = BLANK_VALUE.match?(Utils.encode_utf8_string(text))
    end
  end
end
