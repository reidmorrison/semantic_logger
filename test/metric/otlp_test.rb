require_relative "../test_helper"

module Metric
  class OtlpTest < Minitest::Test
    # The ENV variables that the appender reads, cleared around each test.
    OTEL_ENV = %w[OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_ENDPOINT OTEL_SERVICE_NAME].freeze

    describe SemanticLogger::Metric::Otlp do
      let(:start_time) { Time.at(1_700_000_000, 123_456_789, :nsec) }
      let(:end_time) { Time.at(1_700_000_060, 123_456_789, :nsec) }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new(now: start_time) }
      let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
      let(:options) { {} }
      let(:appender) { new_appender(**options) }

      before do
        @saved_env = OTEL_ENV.to_h { |name| [name, ENV.delete(name)] }
      end

      after do
        @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
      end

      def new_appender(**args)
        stub_http_start { SemanticLogger::Metric::Otlp.new(**args) }
      end

      # Returns a 200 response with the body.
      def success(body = "{}")
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response.define_singleton_method(:body) { body }
        response
      end

      def failure(response_class, code, body = "")
        response = response_class.new("1.1", code.to_s, "Failure")
        response.define_singleton_method(:body) { body }
        response
      end

      # Collects what the aggregator recorded into a snapshot.
      def snapshot
        aggregator.collect(end_time)
      end

      # Writes the snapshot, the server answering with the response, or raising it when it is an exception.
      # Returns what #write_metrics returns; the requests sent are in @requests.
      def write(snapshot = self.snapshot, response: success, on: appender)
        @requests = []
        on.http.stub(:request, lambda { |request|
          @requests << request
          raise response if response.is_a?(Exception)

          response
        }) do
          on.stub(:logger, capture_logger) { on.write_metrics(snapshot) }
        end
      end

      # Returns [Array<Net::HTTPRequest>] the requests sent to write the snapshot.
      def requests(snapshot = self.snapshot, on: appender)
        write(snapshot, on: on)
        @requests
      end

      # Returns [Hash] the body of the single request sent for the snapshot.
      def body(snapshot = self.snapshot, on: appender)
        requests = requests(snapshot, on: on)

        assert_equal 1, requests.size
        JSON.parse(requests.first.body)
      end

      def metrics(snapshot = self.snapshot, on: appender)
        body(snapshot, on: on).dig("resourceMetrics", 0, "scopeMetrics", 0, "metrics")
      end

      def metric(name, snapshot = self.snapshot)
        metrics(snapshot).find { |metric| metric["name"] == name }
      end

      def attributes(list)
        list.to_h { |attribute| [attribute["key"], attribute["value"]] }
      end

      describe "url" do
        it "posts to http://localhost:4318/v1/metrics by default" do
          assert_equal "localhost", appender.server
          assert_equal 4318, appender.port
          assert_equal "/v1/metrics", appender.full_path
        end

        it "posts to v1/metrics under the path of url:" do
          assert_equal "/v1/metrics", new_appender(url: "https://otlp.example.com").full_path
          assert_equal "/otlp/v1/metrics", new_appender(url: "https://otlp.example.com/otlp").full_path
          assert_equal "/otlp/v1/metrics", new_appender(url: "https://otlp.example.com/otlp/").full_path
        end

        it "posts to endpoint: as it is" do
          appender = new_appender(endpoint: "https://otlp.example.com:4443/custom/metrics")

          assert_equal "otlp.example.com", appender.server
          assert_equal 4443, appender.port
          assert_equal "/custom/metrics", appender.full_path
        end

        it "keeps the query string of the url" do
          requests = requests(on: new_appender(url: "http://otlp.example.com/otlp?tenant=a"))

          assert_equal "/otlp/v1/metrics?tenant=a", requests.first.path
        end

        it "refuses both url: and endpoint:" do
          error = assert_raises(ArgumentError) do
            new_appender(url: "http://a.example.com", endpoint: "http://b.example.com/v1/metrics")
          end

          assert_includes error.message, "either url: or endpoint:"
        end

        it "takes the base url from OTEL_EXPORTER_OTLP_ENDPOINT" do
          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://collector.example.com:4318/base"

          assert_equal "collector.example.com", appender.server
          assert_equal "/base/v1/metrics", appender.full_path
        end

        it "takes the endpoint from OTEL_EXPORTER_OTLP_METRICS_ENDPOINT, before OTEL_EXPORTER_OTLP_ENDPOINT" do
          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]         = "http://collector.example.com:4318"
          ENV["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] = "http://metrics.example.com:4318/custom"

          assert_equal "metrics.example.com", appender.server
          assert_equal "/custom", appender.full_path
        end

        it "takes url: before the environment" do
          ENV["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] = "http://metrics.example.com:4318/custom"
          appender = new_appender(url: "http://given.example.com")

          assert_equal "given.example.com", appender.server
          assert_equal "/v1/metrics", appender.full_path
        end

        it "ignores a blank environment variable" do
          ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = " "

          assert_equal "localhost", appender.server
        end
      end

      describe "request" do
        before do
          aggregator.record(:counter, "users.signup", 1)
        end

        it "posts JSON" do
          request = requests.first

          assert_equal "POST", request.method
          assert_equal "/v1/metrics", request.path
          assert_equal "application/json", request["Content-Type"]
        end

        it "sends the headers" do
          request = requests(on: new_appender(header: {"Authorization" => "Bearer TOKEN"})).first

          assert_equal "Bearer TOKEN", request["Authorization"]
        end

        it "compresses the body with gzip" do
          request = requests(on: new_appender(compress: true)).first

          assert_equal "gzip", request["Content-Encoding"]
          json = Zlib::GzipReader.new(StringIO.new(request.body)).read

          metrics = JSON.parse(json).dig("resourceMetrics", 0, "scopeMetrics", 0, "metrics")

          assert_equal(["users.signup"], metrics.map { |metric| metric["name"] })
        end

        it "returns true once the server accepts it" do
          appender.http.stub(:request, success) do
            assert appender.write_metrics(snapshot)
          end
        end
      end

      describe "resource and scope" do
        before do
          aggregator.record(:counter, "users.signup", 1)
        end

        let(:resource) { attributes(body.dig("resourceMetrics", 0, "resource", "attributes")) }

        it "names the service, host, environment, and process" do
          appender = new_appender(application: "shop", host: "web1", environment: "production")
          resource = attributes(body(on: appender).dig("resourceMetrics", 0, "resource", "attributes"))

          assert_equal(
            {
              "process.pid"                 => {"intValue" => Process.pid.to_s},
              "service.name"                => {"stringValue" => "shop"},
              "host.name"                   => {"stringValue" => "web1"},
              "deployment.environment.name" => {"stringValue" => "production"}
            },
            resource
          )
        end

        it "defaults to SemanticLogger.application and SemanticLogger.host, without an environment" do
          SemanticLogger.stub(:environment, nil) do
            assert_equal({"stringValue" => SemanticLogger.application}, resource["service.name"])
            assert_equal({"stringValue" => SemanticLogger.host}, resource["host.name"])
            refute resource.key?("deployment.environment.name")
          end
        end

        it "takes the service name from OTEL_SERVICE_NAME, unless application: is given" do
          ENV["OTEL_SERVICE_NAME"] = "from-env"

          assert_equal({"stringValue" => "from-env"}, resource["service.name"])
          appender = new_appender(application: "given")

          assert_equal(
            {"stringValue" => "given"},
            attributes(body(on: appender).dig("resourceMetrics", 0, "resource", "attributes"))["service.name"]
          )
        end

        it "adds resource_attributes, which replace the others" do
          appender = new_appender(resource_attributes: {"service.version" => "1.2.3", "service.name": "override",
                                                        "process.pid" => 7})
          resource = attributes(body(on: appender).dig("resourceMetrics", 0, "resource", "attributes"))

          assert_equal({"stringValue" => "1.2.3"}, resource["service.version"])
          assert_equal({"stringValue" => "override"}, resource["service.name"])
          assert_equal({"intValue" => "7"}, resource["process.pid"])
        end

        it "is the SemanticLogger scope, with the gem version" do
          scope = body.dig("resourceMetrics", 0, "scopeMetrics", 0, "scope")

          assert_equal({"name" => "SemanticLogger", "version" => SemanticLogger::VERSION}, scope)
        end
      end

      describe "counters" do
        it "is a monotonic delta sum, with an Integer as a String" do
          aggregator.record(:counter, "users.signup", 1)
          aggregator.record(:counter, "users.signup", 2)

          assert_equal(
            {
              "name" => "users.signup",
              "sum"  => {
                "dataPoints"             => [
                  {
                    "startTimeUnixNano" => "1700000000123456789",
                    "timeUnixNano"      => "1700000060123456789",
                    "asInt"             => "3"
                  }
                ],
                "aggregationTemporality" => 1,
                "isMonotonic"            => true
              }
            },
            metric("users.signup")
          )
        end

        it "sends a Float sum as asDouble" do
          aggregator.record(:counter, "cart.value", 2.5)
          aggregator.record(:counter, "cart.value", 1)

          assert_in_delta 3.5, metric("cart.value").dig("sum", "dataPoints", 0, "asDouble")
        end

        it "sends an Integer beyond 64 bits as asDouble" do
          aggregator.record(:counter, "huge", 2**70)

          assert_in_delta (2**70).to_f, metric("huge").dig("sum", "dataPoints", 0, "asDouble")
        end

        it "sends an exact Integer sum that has grown beyond 64 bits as asDouble" do
          3.times { aggregator.record(:counter, "bytes.total", 2**62) }

          point = metric("bytes.total").dig("sum", "dataPoints", 0)

          refute point.key?("asInt")
          assert_in_delta (3 * (2**62)).to_f, point["asDouble"]
        end

        it "leaves out an Integer sum beyond the range of a Float" do
          aggregator.record(:counter, "astronomical", 10**400)
          aggregator.record(:counter, "users.signup", 1)

          assert_equal(["users.signup"], metrics.map { |metric| metric["name"] })
        end

        it "has the unit" do
          aggregator.record(:counter, "bytes.sent", 10, unit: "By")

          assert_equal "By", metric("bytes.sent")["unit"]
        end

        it "leaves out a sum that is not finite, and a metric left without data points" do
          # Built here: the Aggregator keeps every sum finite.
          points   = [
            SemanticLogger::Metric::Snapshot::Point.new(kind: :counter, name: "overflow", value: Float::INFINITY),
            SemanticLogger::Metric::Snapshot::Point.new(kind: :counter, name: "users.signup", value: 1)
          ]
          snapshot = SemanticLogger::Metric::Snapshot.new(start_time: start_time, end_time: end_time, points: points)

          assert_equal(["users.signup"], metrics(snapshot).map { |metric| metric["name"] })
        end

        it "makes the points of a metric with different dimensions data points of one metric" do
          aggregator.record(:counter, "users.signup", 1, dimensions: {plan: "free"})
          aggregator.record(:counter, "users.signup", 2, dimensions: {plan: "premium"})
          aggregator.record(:counter, "users.signup", 4)

          metrics     = self.metrics
          data_points = metrics.first.dig("sum", "dataPoints")
          by_plan     = data_points.to_h do |point|
            [point["attributes"] && attributes(point["attributes"])["plan"]["stringValue"], point["asInt"]]
          end

          assert_equal 1, metrics.size
          assert_equal({"free" => "1", "premium" => "2", nil => "4"}, by_plan)
        end
      end

      describe "names" do
        def point(kind, name, value, **args)
          SemanticLogger::Metric::Snapshot::Point.new(kind: kind, name: name, value: value, **args)
        end

        def histogram(value)
          histogram = SemanticLogger::Metric::ExponentialHistogram.new
          histogram.record(value)
          histogram
        end

        def built(*points)
          SemanticLogger::Metric::Snapshot.new(start_time: start_time, end_time: end_time, points: points)
        end

        it "sends one metric per name, the Aggregator keeping the first kind and unit of each" do
          aggregator.record(:counter, "jobs", 1, unit: "{job}")
          aggregator.record(:histogram, "jobs", 2.0)
          aggregator.record(:counter, "jobs", 1, unit: "s")
          aggregator.record(:counter, :jobs, 1, unit: "{job}")

          metrics = self.metrics

          assert_equal 1, metrics.size
          assert_equal "{job}", metrics.first["unit"]
          assert_equal "2", metrics.first.dig("sum", "dataPoints", 0, "asInt")
        end

        it "sends each unit of one name as a metric of its own, in a merged snapshot" do
          aggregator.record(:counter, "jobs", 1, unit: "{job}")
          first = aggregator.collect(end_time)
          aggregator.record(:counter, "jobs", 2, unit: "s")
          aggregator.record(:counter, "jobs", 3, unit: "s", dimensions: {"queue" => "a"})
          merged  = first.merge(aggregator.collect(end_time + 60))
          metrics = metrics(merged)

          assert_equal(%w[jobs jobs], metrics.map { |metric| metric["name"] })
          by_unit = metrics.to_h do |metric|
            [metric["unit"], metric.dig("sum", "dataPoints").map { |data_point| data_point["asInt"] }]
          end

          assert_equal({"{job}" => %w[1], "s" => %w[2 3]}, by_unit)
        end

        it "sends each kind of one name as a metric of its own, in a snapshot built otherwise" do
          snapshot = built(
            point(:counter, "jobs", 1, unit: "{job}"),
            point(:histogram, "jobs", histogram(2.0)),
            point(:counter, "jobs", 3, unit: "{job}", dimensions: {"queue" => "a"})
          )
          metrics = metrics(snapshot)

          assert_equal 2, metrics.size
          assert_equal(%w[1 3], metrics.first.dig("sum", "dataPoints").map { |data_point| data_point["asInt"] })
          assert_equal "1", metrics.last.dig("exponentialHistogram", "dataPoints", 0, "count")
        end

        it "sends Semantic Logger's own metrics under their own names, apart from the application's" do
          name = SemanticLogger::Metric::InternalMetrics::NAME
          aggregator.record(:counter, "log.processed", 7)
          aggregator.record(:counter, name, 5, dimensions: {appender: "File"}, internal: true)

          by_name = metrics(on: new_appender(internal_metrics: true)).to_h do |metric|
            [metric["name"], metric.dig("sum", "dataPoints", 0, "asInt")]
          end

          assert_equal({"log.processed" => "7", name => "5"}, by_name)
        end

        it "sends both Semantic Logger's own points and an application's of one name, as two metrics" do
          name     = SemanticLogger::Metric::InternalMetrics::NAME
          snapshot = built(point(:counter, name, 7), point(:counter, name, 5, internal: true))
          metrics  = metrics(snapshot)

          assert_equal([name, name], metrics.map { |metric| metric["name"] })
          assert_equal(%w[7 5], metrics.map { |metric| metric.dig("sum", "dataPoints", 0, "asInt") })
        end
      end

      describe "histograms" do
        def data_point(name)
          metric(name).dig("exponentialHistogram", "dataPoints", 0)
        end

        it "is a delta exponential histogram" do
          [0.25, 0.25, 1.5].each { |value| aggregator.record(:histogram, "supplier.add_user", value, unit: "s") }
          metric = metric("supplier.add_user")

          assert_equal "s", metric["unit"]
          assert_equal 1, metric.dig("exponentialHistogram", "aggregationTemporality")
          refute metric.key?("sum")

          point = metric.dig("exponentialHistogram", "dataPoints", 0)

          assert_equal "1700000000123456789", point["startTimeUnixNano"]
          assert_equal "1700000060123456789", point["timeUnixNano"]
        end

        it "has the count, sum, scale, min, max, and buckets" do
          [0.25, 0.25, 1.5].each { |value| aggregator.record(:histogram, "supplier.add_user", value, unit: "s") }
          point = data_point("supplier.add_user")

          assert_equal "3", point["count"]
          assert_in_delta 2.0, point["sum"]
          assert_equal 3, point["scale"]
          assert_equal "0", point["zeroCount"]
          assert_equal [0.25, 1.5], [point["min"], point["max"]]
          refute point.key?("negative")
          # 0.25 = 2**-2 is the upper boundary of bucket -17 at scale 3; 1.5 is in bucket 4.
          assert_equal(-17, point.dig("positive", "offset"))
          counts = point.dig("positive", "bucketCounts")

          assert_equal "2", counts.first
          assert_equal "1", counts.last
          assert_equal 22, counts.size
          assert(counts.all?(String))
        end

        it "has negative buckets and the count of zeros" do
          [-3, 0, 0, 4].each { |value| aggregator.record(:histogram, "temperature", value) }
          point = data_point("temperature")

          assert_equal "4", point["count"]
          assert_equal "2", point["zeroCount"]
          assert_equal({"offset" => 12, "bucketCounts" => ["1"]}, point["negative"])
          assert_equal({"offset" => 15, "bucketCounts" => ["1"]}, point["positive"])
          assert_in_delta(-3.0, point["min"])
          assert_in_delta 4.0, point["max"]
        end

        it "leaves out the sum once a negative value was recorded, as OTLP asks" do
          [-3, 4].each { |value| aggregator.record(:histogram, "temperature", value) }
          point = data_point("temperature")

          assert_equal "2", point["count"]
          refute point.key?("sum")
        end

        it "leaves out empty buckets" do
          aggregator.record(:histogram, "zeros", 0)
          point = data_point("zeros")

          refute point.key?("positive")
          refute point.key?("negative")
          assert_equal "1", point["zeroCount"]
        end

        it "leaves out a sum that is not finite" do
          aggregator.record(:histogram, "large", Float::MAX)
          aggregator.record(:histogram, "large", Float::MAX)
          point = data_point("large")

          assert_equal "2", point["count"]
          refute point.key?("sum")
          assert_in_delta Float::MAX, point["max"]
        end

        it "has a sum of zero, and leaves out the min and max, of an empty histogram" do
          histogram = SemanticLogger::Metric::ExponentialHistogram.new
          point     = SemanticLogger::Metric::Snapshot::Point.new(kind: :histogram, name: "empty", value: histogram)
          snapshot  = SemanticLogger::Metric::Snapshot.new(start_time: start_time, end_time: end_time, points: [point])
          data      = metrics(snapshot).first.dig("exponentialHistogram", "dataPoints", 0)

          assert_equal "0", data["count"]
          assert_in_delta 0.0, data["sum"]
          refute data.key?("min")
          refute data.key?("max")
          refute data.key?("positive")
        end
      end

      describe "dimensions" do
        # Given to the encoder as they are, in a point built here: the Aggregator would first normalize
        # them to Strings, scalars, and Arrays of scalars (see Aggregator.normalize_dimensions), so the
        # rest only checks that the encoder does not fail on a snapshot built otherwise.
        let(:dimensions) do
          point = SemanticLogger::Metric::Snapshot::Point.new(
            kind: :counter, name: "calls", value: 1, dimensions: dimension_values
          )
          snapshot = SemanticLogger::Metric::Snapshot.new(start_time: start_time, end_time: end_time, points: [point])
          attributes(metric("calls", snapshot).dig("sum", "dataPoints", 0, "attributes"))
        end

        let(:dimension_values) do
          {
            string:      "premium",
            symbol:      :free,
            integer:     42,
            big_integer: 2**64,
            float:       1.5,
            nan:         Float::NAN,
            infinity:    -Float::INFINITY,
            "true"      => true,
            "false"     => false,
            nil:         nil,
            array:       ["a", 1, [true]],
            hash:        {region: "us"},
            other:       Time.at(0).utc,
            "string.key" => "kept"
          }
        end

        it "maps each value to an AnyValue" do
          assert_equal(
            {
              "string"      => {"stringValue" => "premium"},
              "symbol"      => {"stringValue" => "free"},
              "integer"     => {"intValue" => "42"},
              "big_integer" => {"stringValue" => (2**64).to_s},
              "float"       => {"doubleValue" => 1.5},
              "nan"         => {"doubleValue" => "NaN"},
              "infinity"    => {"doubleValue" => "-Infinity"},
              "true"        => {"boolValue" => true},
              "false"       => {"boolValue" => false},
              "nil"         => {},
              "array"       => {
                "arrayValue" => {
                  "values" => [{"stringValue" => "a"}, {"intValue" => "1"}, {"stringValue" => "[true]"}]
                }
              },
              "hash"        => {"stringValue" => {region: "us"}.inspect},
              "other"       => {"stringValue" => Time.at(0).utc.to_s},
              "string.key"  => {"stringValue" => "kept"}
            },
            dimensions
          )
        end

        describe "nested deeply" do
          let(:dimension_values) do
            nested = ["bottom"]
            12.times { nested = [nested] }
            {deep: nested}
          end

          it "sends an Array within an Array as the String of its inspect" do
            value = dimensions["deep"].dig("arrayValue", "values", 0)

            assert_equal SemanticLogger::Utils.safe_inspect(dimension_values[:deep].first), value["stringValue"]
          end
        end

        describe "as normalized by the Aggregator" do
          let(:dimensions) do
            aggregator.record(:counter, "calls", 1, dimensions: dimension_values)
            attributes(metric("calls").dig("sum", "dataPoints", 0, "attributes"))
          end

          let(:dimension_values) do
            {plan: :free, ids: [1, "a", :b], nested: {region: "us"}, nan: Float::NAN, big: 2**64}
          end

          it "maps each value to an AnyValue" do
            assert_equal({"stringValue" => "free"}, dimensions["plan"])
            assert_equal(
              {"arrayValue" => {"values" => [{"intValue" => "1"}, {"stringValue" => "a"}, {"stringValue" => "b"}]}},
              dimensions["ids"]
            )
            assert dimensions["nested"].key?("stringValue")
            assert dimensions["nan"].key?("stringValue")
            assert_equal({"stringValue" => (2**64).to_s}, dimensions["big"])
          end
        end

        describe "invalid UTF-8" do
          let(:dimension_values) { {"name" => "caf\xC3".b, "bin\xFF".b => "ok"} }

          it "is sent as valid UTF-8" do
            assert_equal({"stringValue" => "caf"}, dimensions["name"])
            assert_equal({"stringValue" => "ok"}, dimensions["bin"])
          end
        end
      end

      describe "internal metrics" do
        def deliver(appender)
          aggregator.record(:counter, "users.signup", 1)
          aggregator.record(:counter, "semantic_logger.log.processed", 5,
                            dimensions: {appender: "File"}, internal: true)
          requests = []
          appender.http.stub(:request, lambda { |request|
            requests << request
            success
          }) do
            appender.log_metrics(snapshot)
          end
          requests.map { |request| JSON.parse(request.body) }
        end

        def names(bodies)
          bodies.flat_map do |body|
            body.dig("resourceMetrics", 0, "scopeMetrics", 0, "metrics").map { |metric| metric["name"] }
          end
        end

        it "leaves them out by default" do
          assert_equal ["users.signup"], names(deliver(new_appender(interval: 1)))
        end

        it "sends them with internal_metrics: true" do
          assert_equal %w[users.signup semantic_logger.log.processed],
                       names(deliver(new_appender(interval: 1, internal_metrics: true)))
        end
      end

      describe "responses" do
        before do
          aggregator.record(:counter, "users.signup", 1)
        end

        it "reports a partial success on the internal logger" do
          body = {partialSuccess: {rejectedDataPoints: "2", errorMessage: "bad unit"}}.to_json

          assert write(response: success(body))
          event = capture_logger.events.last

          assert_equal :warn, event.level
          assert_includes event.message, "rejected 2 metric data point(s)"
          assert_includes event.message, "bad unit"
        end

        it "reports nothing for a partialSuccess with nothing rejected, an empty body, or one that is not JSON" do
          ["", "{}", {partialSuccess: {}}.to_json, "not json", "\x00\x01"].each do |body|
            write(response: success(body))
          end

          assert_empty(capture_logger.events.reject { |event| event.level == :trace })
        end

        it "reports a partial success whose fields are not what OTLP says, without raising" do
          [
            {rejectedDataPoints: "many", errorMessage: "odd count"},
            {rejectedDataPoints: [1], errorMessage: {detail: "a Hash"}},
            {rejectedDataPoints: 2.0},
            {rejectedDataPoints: nil, errorMessage: 42}
          ].each { |partial| assert write(response: success({partialSuccess: partial}.to_json)) }

          messages = capture_logger.events.select { |event| event.level == :warn }.map(&:message)

          assert_equal 4, messages.size
          assert_includes messages[0], "rejected 0 metric data point(s): \"odd count\""
          assert_includes messages[1], "rejected 0 metric data point(s)"
          assert_includes messages[2], "rejected 2 metric data point(s)"
          assert_includes messages[3], "rejected 0 metric data point(s): \"42\""
        end

        it "reads a rejectedDataPoints String in base 10 only" do
          [{rejectedDataPoints: "010"}, {rejectedDataPoints: "0x10", errorMessage: "hex"}].each do |partial|
            assert write(response: success({partialSuccess: partial}.to_json))
          end

          messages = capture_logger.events.select { |event| event.level == :warn }.map(&:message)

          assert_equal 2, messages.size
          assert_includes messages[0], "rejected 10 metric data point(s)"
          assert_includes messages[1], "rejected 0 metric data point(s): \"hex\""
        end

        it "reports nothing for a partialSuccess that is not a Hash, or a body nested too deeply" do
          [{partialSuccess: "none"}.to_json, "[1]", "#{'[' * 200}#{']' * 200}"].each do |body|
            assert write(response: success(body))
          end

          assert_empty(capture_logger.events.reject { |event| event.level == :trace })
        end

        it "raises for a request the server rejects" do
          assert_raises(SemanticLogger::Appender::Http::ResponseError) do
            write(response: failure(Net::HTTPBadRequest, 400, "bad request"))
          end
        end

        it "raises for a 500, which the server may have stored" do
          assert_raises(SemanticLogger::Appender::Http::ResponseError) do
            write(response: failure(Net::HTTPInternalServerError, 500))
          end
        end

        describe "#metrics_retryable?" do
          def response_error(response_class, code)
            write(response: failure(response_class, code))

            flunk "Expected a ResponseError"
          rescue SemanticLogger::Appender::Http::ResponseError => e
            e
          end

          [
            [Net::HTTPRequestTimeOut, 408], [Net::HTTPTooManyRequests, 429], [Net::HTTPBadGateway, 502],
            [Net::HTTPServiceUnavailable, 503], [Net::HTTPGatewayTimeOut, 504]
          ].each do |response_class, code|
            it "is true after a #{code}, which OTLP/HTTP retries" do
              assert appender.metrics_retryable?(response_error(response_class, code))
            end
          end

          [
            [Net::HTTPBadRequest, 400], [Net::HTTPUnauthorized, 401], [Net::HTTPInternalServerError, 500],
            [Net::HTTPNotImplemented, 501]
          ].each do |response_class, code|
            it "is false after a #{code}" do
              refute appender.metrics_retryable?(response_error(response_class, code))
            end
          end

          it "is true when the server cannot be reached" do
            assert appender.metrics_retryable?(Errno::ECONNREFUSED.new)
          end

          it "is false for any other error" do
            refute appender.metrics_retryable?(RuntimeError.new("boom"))
          end
        end

        describe "sent again" do
          let(:options) { {interval: 1} }

          # Gives the snapshot to the appender, as the collector does, the server answering with the
          # response, or raising it when it is an exception. Returns what #log_metrics returns.
          def deliver(snapshot, response: success)
            @requests = []
            appender.http.stub(:request, lambda { |request|
              @requests << request
              raise response if response.is_a?(Exception)

              response
            }) do
              appender.stub(:logger, capture_logger) { appender.log_metrics(snapshot) }
            end
          end

          # Returns [Hash] the data point of the single request sent.
          def sent_point
            assert_equal 1, @requests.size
            JSON.parse(@requests.first.body).dig(
              "resourceMetrics", 0, "scopeMetrics", 0, "metrics", 0, "sum", "dataPoints", 0
            )
          end

          {
            "503"                  => -> { failure(Net::HTTPServiceUnavailable, 503) },
            "502"                  => -> { failure(Net::HTTPBadGateway, 502) },
            "504"                  => -> { failure(Net::HTTPGatewayTimeOut, 504) },
            "a refused connection" => -> { Errno::ECONNREFUSED.new }
          }.each_pair do |reason, response|
            it "merges a snapshot into the next one after #{reason}" do
              refute deliver(snapshot, response: instance_exec(&response))
              assert_equal :warn, capture_logger.events.last.level

              aggregator.record(:counter, "users.signup", 2)

              assert deliver(aggregator.collect(end_time + 60))
              point = sent_point

              assert_equal "3", point["asInt"]
              assert_equal "1700000000123456789", point["startTimeUnixNano"]
              assert_equal "1700000120123456789", point["timeUnixNano"]
            end
          end

          it "discards a snapshot that the server rejected" do
            refute deliver(snapshot, response: failure(Net::HTTPBadRequest, 400))
            assert_equal :error, capture_logger.events.last.level

            aggregator.record(:counter, "users.signup", 2)

            assert deliver(aggregator.collect(end_time + 60))
            assert_equal "2", sent_point["asInt"]
          end

          it "sends what it kept on flush" do
            refute deliver(snapshot, response: failure(Net::HTTPServiceUnavailable, 503))
            @requests = []
            appender.http.stub(:request, lambda { |request|
              @requests << request
              success
            }) do
              appender.stub(:logger, capture_logger) { appender.flush }
            end

            assert_equal "1", sent_point["asInt"]
          end
        end
      end

      it "is added with metric: :otlp" do
        stub_http_start do
          appender = SemanticLogger.add_appender(metric: :otlp, interval: 10)

          assert_instance_of SemanticLogger::Metric::Otlp, appender
          assert_equal 10, appender.metrics_interval
          refute appender.should_log?(SemanticLogger::Log.new("Test", :info))
        ensure
          SemanticLogger.remove_appender(appender)
        end
      end
    end
  end
end
