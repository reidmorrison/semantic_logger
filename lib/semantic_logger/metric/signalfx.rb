# Forward application metrics to Splunk Observability Cloud, formerly SignalFx.
#
# Example:
#   SemanticLogger.add_appender(
#     metric: :splunk_observability,
#     token:  'SIGNALFX_ORG_ACCESS_TOKEN'
#   )
#
# `metric: :signalfx` adds the same appender.
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
    # A "/" in a name becomes a ".", and a leading, trailing, or repeated "/" is left out; a series whose
    # name is then empty is not sent, with a warning on the internal logger once per name. The series of
    # histograms that are then sent with the same name and the same dimensions, once their blank values
    # are left out, are merged first: such as "a/b" and "a.b" with the same non-blank dimensions, but not
    # "a/b" and "a.b" without any, since "a/b" is then sent as "Application" (see below). A histogram
    # series with another unit than the first one merged is left out, with a warning once per name. Each
    # datapoint has the dimensions of its series, with each value as text, leaving out those whose value
    # is blank (nil, or text that is empty or only whitespace), and the `host`, `application`, and, when
    # it is set, `environment` of the appender, unless the series has a dimension of that name of its own,
    # which it keeps.
    #
    # A series whose name holds a "/", and that has no dimensions (or only blank ones), is sent as
    # Semantic Logger 5 sent such a metric, so that existing charts keep working: the class and action
    # are taken from its name, as the dimensions `class` and `action`, and the metric is named
    # "Application". For example a counter "Common/User/authorize" is sent as the counter
    # "Application.counter", with the dimensions `class: "Common::User", action: "authorize"`; a histogram
    # of that name as "Application.counter" (the count), "Application.average" (the mean), and
    # "Application.sum", "Application.min", ... "Application.p99".
    #
    # Counters with the same name and dimensions are added together, so a counter named as one of the
    # names that a histogram is sent as, such as a counter "latency.count" and a histogram "latency", is
    # sent as one counter, holding both. A request holds one datapoint of each name and dimensions,
    # though: a gauge with the name and dimensions of a counter, or of another gauge, such as the gauge
    # "latency.max" of a histogram "latency" and a counter, or a histogram, "latency.max", is left out,
    # keeping the first one, with a warning on the internal logger once per name.
    #
    # A value beyond the range of a Float, such as the sum of a histogram of huge values, cannot be sent:
    # its datapoint is left out, with a warning on the internal logger once per name. A counter beyond the
    # range of a 64-bit Integer is sent as a Float.
    #
    # It warns about at most WARNINGS_LIMIT names, each once, so that names built from values cannot use
    # up the memory.
    #
    # A snapshot that the server asks to send again later (408, 429, 503), or that could not be sent
    # since the server could not be reached, is kept and sent with the next one (see
    # Metric::Snapshots#metrics_retryable?).
    class Signalfx < SemanticLogger::Appender::Http
      include Snapshots

      attr_reader :full_path

      END_POINT = "v2/datapoint".freeze

      # The name of the metric that a series named as "Class/action", without dimensions, is sent as.
      CLASS_ACTION_METRIC = "Application".freeze

      # The quantiles sent for each histogram, by the suffix of their names.
      QUANTILES = {"p50" => 0.5, "p95" => 0.95, "p99" => 0.99}.freeze

      # Most metric names that it warns about, each once for each problem.
      WARNINGS_LIMIT = 1000

      # Text of a dimension value that is blank (see #blank_value?).
      BLANK_VALUE = /\A[[:space:]]*\z/
      private_constant :BLANK_VALUE

      # The body of one request: the `counter` and `gauge` datapoints of a snapshot, each stamped with the
      # end of its interval, in milliseconds. Counters with the same name and dimensions, such as a
      # counter and the count of a histogram both named "Class/action", are added together. A gauge with
      # the name and dimensions of a datapoint already added, or a counter with those of a gauge, is left
      # out (see #conflicts).
      #
      # Leaves out a datapoint whose value is beyond the range of a Float, which JSON cannot hold, and sends
      # an Integer beyond the range of a 64-bit Integer, which SignalFx cannot hold, as a Float.
      class Datapoints
        # Largest Integer value that SignalFx takes as an Integer.
        MAX_INTEGER = (2**63) - 1

        def initialize(time)
          @timestamp = (time.to_r * 1000).to_i
          @counters  = {}
          @gauges    = {}
          @conflicts = []
        end

        def counter(metric, value, dimensions)
          key = [metric, dimensions]
          return @conflicts << metric if @gauges.key?(key)

          existing = @counters[key]
          if existing
            existing[:value] += value
          else
            @counters[key] = datapoint(metric, value, dimensions)
          end
        end

        def gauge(metric, value, dimensions)
          key = [metric, dimensions]
          return @conflicts << metric if @counters.key?(key) || @gauges.key?(key)

          @gauges[key] = datapoint(metric, value, dimensions)
        end

        # Returns [Hash] the datapoints by type, leaving out a type without any, and the datapoints whose
        # value cannot be sent (see #left_out).
        def to_h
          data           = {}
          counters       = sendable(@counters.values)
          gauges         = sendable(@gauges.values)
          data[:counter] = counters unless counters.empty?
          data[:gauge]   = gauges unless gauges.empty?
          data
        end

        # Returns [Array<String>] the names of the datapoints that #to_h leaves out, since their value is
        # beyond the range of a Float.
        def left_out
          (@counters.values + @gauges.values).filter_map do |datapoint|
            datapoint[:metric] unless sendable?(datapoint)
          end.uniq
        end

        # Returns [Array<String>] the names of the datapoints left out since a datapoint of another type, or a
        # gauge, with the same name and dimensions was added first.
        def conflicts = @conflicts.uniq

        private

        def sendable(datapoints)
          datapoints.filter_map do |datapoint|
            next unless sendable?(datapoint)

            value = datapoint[:value]
            value.is_a?(Integer) && value.abs > MAX_INTEGER ? datapoint.merge(value: value.to_f) : datapoint
          end
        end

        def sendable?(datapoint)
          value = datapoint[:value]
          value.is_a?(Integer) ? value.to_f.finite? : value.finite?
        end

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
        @full_path            = "#{@path.end_with?('/') ? @path : "#{@path}/"}#{END_POINT}"
        @warned               = {}
      end

      # Posts the datapoints of the snapshot in one request, unless it has none. Raises
      # Appender::Http::ResponseError when the server does not accept it.
      def write_metrics(snapshot)
        datapoints = datapoints(snapshot)
        warn_once(:range, datapoints.left_out) do |names|
          "Left out the metrics #{names.join(', ')} of this interval: beyond the range of a Float. " \
            "Further ones of these names are left out without a warning."
        end
        warn_once(:conflict, datapoints.conflicts) do |names|
          "Left out the datapoints #{names.join(', ')} of this interval: a counter or gauge with the same name " \
            "and dimensions was sent instead. Further ones of these names are left out without a warning."
        end
        data = datapoints.to_h
        return true if data.empty?

        body = Utils.to_json(data)
        logger.trace(body)
        post(body, full_path)
      end

      # Whether the snapshot is worth sending again with the next one (see
      # Metric::Snapshots#metrics_retryable?): the server stored none of it, since it asked for it to be
      # sent again later, or could not be reached (see Appender::Http#wrote_nothing?). It is sent in one
      # request, so a failure stored none of it.
      def metrics_retryable?(exception) = wrote_nothing?(exception)

      private

      # Returns [Datapoints] the datapoints of the snapshot. Its counters are added to the datapoints as
      # they come; its histograms are merged by the name and dimensions that they are sent with first.
      def datapoints(snapshot)
        datapoints = Datapoints.new(snapshot.end_time)
        histograms = {}
        snapshot.each do |point|
          name, dimensions, class_action = series(point)
          next unless name

          if point.counter?
            datapoints.counter(class_action ? "#{name}.counter" : name, point.value, dimensions)
          else
            add_to_histograms(histograms, point, [name, dimensions, class_action])
          end
        end
        histograms.each_pair { |series, (unit, histogram)| add_histogram(datapoints, series, unit, histogram) }
        datapoints
      end

      # Adds the histogram of the point to the one sent with the same name and dimensions, copied once
      # rather than frozen as the points hold it, unless it is empty, or that one has another unit, as the
      # Aggregator leaves out a record of a name with another unit, warning once per name.
      def add_to_histograms(histograms, point, key)
        return if point.value.empty?

        entry = histograms[key]
        if entry.nil?
          histograms[key] = [point.unit, point.value]
        elsif entry[0] == point.unit
          entry[1] = entry[1].dup if entry[1].frozen?
          entry[1].merge(point.value)
        else
          unit_conflict(key[0], entry[0], point.unit)
        end
      end

      def unit_conflict(name, unit, other)
        warn_once(:unit, [name]) do
          "Left out a series of the histogram #{name.inspect} with the unit #{other.inspect}, since it is sent " \
            "with the unit #{unit.inspect}. Further ones of this name are left out without a warning."
        end
      end

      # Returns [Array] the name to send the point under, its dimensions, and whether the name is
      # CLASS_ACTION_METRIC, with the class and action taken from the point's name. Nil when its name
      # holds nothing but "/".
      def series(point)
        name  = Utils.encode_utf8_string(point.name.to_s)
        names = name.split("/").reject(&:empty?)
        return empty_name(name) if names.empty?

        dimensions = present_dimensions(point.dimensions)
        if dimensions.empty? && names.size > 1
          action     = names.pop
          dimensions = {"class" => names.join("::"), "action" => action}
          [CLASS_ACTION_METRIC, add_default_dimensions(dimensions), true]
        else
          [names.join("."), add_default_dimensions(dimensions), false]
        end
      end

      # Warns, once per name, that a series whose name holds nothing but "/" is not sent. Returns nil.
      def empty_name(name)
        warn_once(:empty_name, [name]) do
          "Left out the metric #{name.inspect}: its name is empty once each \"/\" is left out"
        end
        nil
      end

      # Warns about the names not yet warned about for the problem, in one warning, whose message the block
      # returns for them, up to WARNINGS_LIMIT names in all. Called holding the lock of the snapshots (see
      # Metric::Snapshots).
      def warn_once(problem, names)
        names = names.reject { |name| @warned.key?([problem, name]) }.first(WARNINGS_LIMIT - @warned.size)
        return if names.empty?

        names.each { |name| @warned[[problem, name]] = true }
        logger.warn(yield(names))
      end

      # Adds the count, sum, mean, min, max, and quantiles of the histogram of the series (see #series), in
      # milliseconds for one of durations in seconds.
      def add_histogram(datapoints, series, unit, histogram)
        name, dimensions, class_action = series
        scale = unit == "s" ? 1000 : 1
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

      # Adds the host, application, and, when set, environment of the appender to the dimensions, unless the
      # metric has a dimension of that name of its own, which it keeps.
      def add_default_dimensions(dimensions)
        dimensions["host"]        ||= host if host
        dimensions["application"] ||= application if application
        dimensions["environment"] ||= environment if environment
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
