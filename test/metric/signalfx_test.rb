require_relative "../test_helper"

module Metric
  class SignalfxTest < Minitest::Test
    describe SemanticLogger::Metric::Signalfx do
      let(:start_time) { Time.at(1_700_000_000) }
      let(:end_time) { start_time + 60 }
      let(:timestamp) { 1_700_000_060_000 }
      let(:defaults) { {"host" => "web1", "application" => "shop", "environment" => "test"} }
      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new(now: start_time) }

      def build_appender(**args)
        stub_http_start do
          SemanticLogger::Metric::Signalfx.new(token: "TEST", host: "web1", application: "shop",
                                               environment: "test", **args)
        end
      end

      let(:appender) { build_appender }

      # Records each metric, given as the arguments of Aggregator#record, and returns the snapshot.
      def snapshot(*metrics)
        metrics.each { |args| aggregator.record(*args[0..2], **(args[3] || {})) }
        aggregator.collect(end_time)
      end

      # Returns [Array<Net::HTTPRequest>] the requests the appender sends while the block runs.
      def capture_requests(appender = self.appender, &block)
        requests = []
        appender.http.stub(:request, lambda { |request|
          requests << request
          http_success
        }, &block)
        requests
      end

      # Returns [Hash] the parsed body of the one request posted for the snapshot.
      def body(snapshot, appender = self.appender)
        requests = capture_requests(appender) { appender.write_metrics(snapshot) }

        assert_equal 1, requests.size
        JSON.parse(requests.first.body)
      end

      def datapoint(metric, value, dimensions = {})
        {"metric" => metric, "value" => value, "dimensions" => dimensions.merge(defaults), "timestamp" => timestamp}
      end

      describe "counters" do
        it "sends each series as a counter of what was added in the interval, with its dimensions" do
          data = body(
            snapshot(
              [:counter, "users.signup", 1],
              [:counter, "users.signup", 2],
              [:counter, "cart.items_added", 3, {dimensions: {department: "clothing"}}]
            )
          )

          assert_equal(
            {
              "counter" => [
                datapoint("users.signup", 3),
                datapoint("cart.items_added", 3, {"department" => "clothing"})
              ]
            },
            data
          )
        end

        it "sends a name with a / under its own name, with the / as a ., when it has dimensions" do
          data = body(snapshot([:counter, "/Filter/count", 1, {dimensions: {state: "FL"}}]))

          assert_equal({"counter" => [datapoint("Filter.count", 1, {"state" => "FL"})]}, data)
        end

        it "sends a name with a / and no dimensions as Application.counter, with the class and action" do
          data = body(snapshot([:counter, "Common/User/authorize", 2]))

          assert_equal(
            {"counter" => [datapoint("Application.counter", 2, {"class" => "Common::User", "action" => "authorize"})]},
            data
          )
        end

        it "takes the class and action from the name of a series whose dimensions are all blank" do
          data = body(snapshot([:counter, "/user/login", 1, {dimensions: {state: "", user: nil, plan: "  "}}]))

          assert_equal(
            {"counter" => [datapoint("Application.counter", 1, {"class" => "user", "action" => "login"})]},
            data
          )
        end

        it "leaves out a repeated or trailing / of a name" do
          data = body(
            snapshot(
              [:counter, "Common//User/authorize/", 1],
              [:counter, "Filter//count/", 2, {dimensions: {state: "FL"}}]
            )
          )

          assert_equal(
            [
              datapoint("Application.counter", 1, {"class" => "Common::User", "action" => "authorize"}),
              datapoint("Filter.count", 2, {"state" => "FL"})
            ],
            data["counter"]
          )
        end

        it "sends a name with one part and a trailing / under that part, without a class" do
          data = body(snapshot([:counter, "jobs/", 1]))

          assert_equal({"counter" => [datapoint("jobs", 1)]}, data)
        end

        it "leaves out a series whose name holds nothing but /, warning once per name" do
          messages = []
          requests = nil
          appender.logger.stub(:warn, ->(message) { messages << message }) do
            requests = capture_requests do
              appender.write_metrics(snapshot([:counter, "//", 1], [:counter, "jobs", 1]))
              appender.write_metrics(snapshot([:counter, "//", 1]))
            end
          end

          assert_equal 1, requests.size
          assert_equal({"counter" => [datapoint("jobs", 1)]}, JSON.parse(requests.first.body))
          assert_equal 1, messages.size
          assert_includes messages.first, '"//"'
        end

        it "sends a sum beyond the range of a 64-bit Integer as a Float" do
          data = body(snapshot([:counter, "jobs", 2**64]))

          assert_equal({"counter" => [datapoint("jobs", 2.0**64)]}, data)
        end

        it "sends a dotted name without dimensions under its own name, without a class" do
          data = body(snapshot([:counter, "users.signup", 1]))

          assert_equal({"counter" => [datapoint("users.signup", 1)]}, data)
        end

        it "leaves out the blank values of dimensions that have others, and sends each value as text" do
          data = body(snapshot([:counter, "jobs", 1, {dimensions: {queue: "high", state: "", retries: 3}}]))

          assert_equal({"counter" => [datapoint("jobs", 1, {"queue" => "high", "retries" => "3"})]}, data)
        end

        it "keeps a dimension whose value is NUL, which is not whitespace" do
          data = body(snapshot([:counter, "jobs", 1, {dimensions: {state: "\0"}}]))

          assert_equal({"state" => "\0"}.merge(defaults), data["counter"].first["dimensions"])
        end

        it "sends a name that is not valid UTF-8" do
          data = body(snapshot([:counter, "users.\xFFsignup".b, 1]))

          assert_equal SemanticLogger::Utils.encode_utf8_string("users.\xFFsignup".b), data["counter"].first["metric"]
        end

        it "sends the overflow series of a metric with too many series" do
          aggregator = SemanticLogger::Metric::Aggregator.new(series_limit: 1, now: start_time)
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 1})
          aggregator.record(:counter, "jobs", 1, dimensions: {id: 2})
          data = body(aggregator.collect(end_time))

          assert_equal(
            [datapoint("jobs", 1, {"id" => "1"}), datapoint("jobs", 1, {"otel.metric.overflow" => "true"})],
            data["counter"]
          )
        end

        it "keeps the metric's own dimensions named host, application, or environment" do
          own  = {host: "db1", application: "billing", environment: "staging", region: "east"}
          data = body(snapshot([:counter, "jobs", 1, {dimensions: own}]))

          sent = data["counter"].map { |point| point["dimensions"] }

          assert_equal [own.transform_keys(&:to_s)], sent
        end

        it "adds the appender's own for a dimension of those names whose value is blank" do
          blank = {host: " ", application: nil, environment: "", region: "east"}
          data  = body(snapshot([:counter, "jobs", 1, {dimensions: blank}]))

          assert_equal({"counter" => [datapoint("jobs", 1, {"region" => "east"})]}, data)
        end

        it "keeps the metric's own environment when the appender has none" do
          appender = build_appender(environment: nil)
          SemanticLogger.stub(:environment, nil) do
            data = body(snapshot([:counter, "jobs", 1, {dimensions: {environment: "staging"}}]), appender)

            assert_equal "staging", data["counter"].first["dimensions"]["environment"]
          end
        end

        it "leaves out the environment when none is set" do
          appender = build_appender(environment: nil)
          SemanticLogger.stub(:environment, nil) do
            data = body(snapshot([:counter, "jobs", 1]), appender)

            assert_equal({"host" => "web1", "application" => "shop"}, data["counter"].first["dimensions"])
          end
        end
      end

      describe "histograms" do
        # Returns [Array<Hash>] the expected quantile gauges for the histogram of the snapshot.
        def quantiles(snapshot, name, dimensions = {}, scale: 1000)
          histogram = snapshot.points.first.value
          {"p50" => 0.5, "p95" => 0.95, "p99" => 0.99}.map do |suffix, probability|
            datapoint("#{name}.#{suffix}", histogram.quantile(probability) * scale, dimensions)
          end
        end

        it "sends the count and sum as counters, and the mean, min, max, and quantiles as gauges, in ms" do
          dimensions = {department: "clothing"}
          snapshot   = snapshot(
            *[0.25, 0.5, 0.75].map do |value|
              [:histogram, "supplier.add_user", value, {unit: "s", dimensions: dimensions}]
            end
          )
          sent = {"department" => "clothing"}

          assert_equal(
            {
              "counter" => [
                datapoint("supplier.add_user.count", 3, sent),
                datapoint("supplier.add_user.sum", 1500.0, sent)
              ],
              "gauge"   => [
                datapoint("supplier.add_user", 500.0, sent),
                datapoint("supplier.add_user.min", 250.0, sent),
                datapoint("supplier.add_user.max", 750.0, sent),
                *quantiles(snapshot, "supplier.add_user", sent)
              ]
            },
            body(snapshot)
          )
        end

        it "sends the values of a histogram in another unit as they are" do
          snapshot = snapshot([:histogram, "upload.size", 2048, {unit: "By"}],
                              [:histogram, "upload.size", 1024, {unit: "By"}])

          assert_equal(
            {
              "counter" => [datapoint("upload.size.count", 2), datapoint("upload.size.sum", 3072.0)],
              "gauge"   => [
                datapoint("upload.size", 1536.0),
                datapoint("upload.size.min", 1024.0),
                datapoint("upload.size.max", 2048.0),
                *quantiles(snapshot, "upload.size", scale: 1)
              ]
            },
            body(snapshot)
          )
        end

        it "sends a name with a / and no dimensions as Application.counter, Application.average, and so on" do
          snapshot = snapshot([:histogram, "Common/User/authorize", 0.5, {unit: "s"}])
          sent     = {"class" => "Common::User", "action" => "authorize"}

          assert_equal(
            {
              "counter" => [datapoint("Application.counter", 1, sent), datapoint("Application.sum", 500.0, sent)],
              "gauge"   => [
                datapoint("Application.average", 500.0, sent),
                datapoint("Application.min", 500.0, sent),
                datapoint("Application.max", 500.0, sent),
                *quantiles(snapshot, "Application", sent)
              ]
            },
            body(snapshot)
          )
        end

        it "adds together a counter and the count of a histogram of the same Class/action name" do
          # Names that only the leading "/" tells apart: the Aggregator keeps one kind per name.
          data = body(snapshot([:counter, "user/login", 2], [:histogram, "/user/login", 0.5, {unit: "s"}]))

          assert_equal(
            [
              datapoint("Application.counter", 3, {"class" => "user", "action" => "login"}),
              datapoint("Application.sum", 500.0, {"class" => "user", "action" => "login"})
            ],
            data["counter"]
          )
        end

        it "merges the histograms sent with the same name and dimensions, sending each gauge once" do
          data = body(
            snapshot(
              [:histogram, "a/b", 1.0, {dimensions: {region: "us"}}],
              [:histogram, "a.b", 3.0, {dimensions: {region: "us"}}],
              [:histogram, "a.b", 5.0, {dimensions: {region: "us", state: ""}}]
            )
          )
          sent = {"region" => "us"}

          assert_equal [datapoint("a.b.count", 3, sent), datapoint("a.b.sum", 9.0, sent)], data["counter"]
          gauges = data["gauge"].to_h { |point| [point["metric"], point] }

          assert_equal data["gauge"].size, gauges.size
          assert_in_delta 3.0, gauges["a.b"]["value"]
          assert_in_delta 1.0, gauges["a.b.min"]["value"]
          assert_in_delta 5.0, gauges["a.b.max"]["value"]
        end

        it "merges histograms without changing those of the snapshot" do
          snapshot = snapshot(
            [:histogram, "a.b", 1.0, {dimensions: {region: "us"}}],
            [:histogram, "a.b", 3.0, {dimensions: {region: "us", state: ""}}]
          )
          body(snapshot)

          assert_equal([1, 1], snapshot.points.map { |point| point.value.count })
        end

        it "sends a name with the unit it was first given, when a merged snapshot has another" do
          earlier = SemanticLogger::Metric::Aggregator.new(now: start_time - 60)
          earlier.record(:histogram, "upload", 2.0, unit: "s")
          aggregator.record(:histogram, "upload", 1500, unit: "By")
          merged   = earlier.collect(start_time).merge(aggregator.collect(end_time))
          messages = []
          data     = nil
          appender.logger.stub(:warn, ->(message) { messages << message }) do
            data = body(merged)
            body(merged)
          end

          assert_equal [datapoint("upload.count", 1), datapoint("upload.sum", 2000.0)], data["counter"]
          assert_equal 1, messages.size
          assert_includes messages.first, '"upload" with the unit "By"'
        end

        it "leaves out a gauge with the name and dimensions of a counter, warning once per name" do
          messages = []
          data     = nil
          appender.logger.stub(:warn, ->(message) { messages << message }) do
            data = body(snapshot([:counter, "latency.max", 7], [:histogram, "latency", 2.0]))
            body(snapshot([:counter, "latency.max", 7], [:histogram, "latency", 2.0]))
          end
          gauges = data["gauge"].map { |point| point["metric"] }

          assert_includes data["counter"], datapoint("latency.max", 7)
          refute_includes gauges, "latency.max"
          assert_includes gauges, "latency.min"
          assert_equal 1, messages.size
          assert_includes messages.first, "latency.max"
        end

        it "sends one gauge of each name and dimensions, the first one" do
          messages = []
          data     = nil
          appender.logger.stub(:warn, ->(message) { messages << message }) do
            data = body(snapshot([:histogram, "latency", 2.0], [:histogram, "latency.min", 9.0]))
          end
          mins = data["gauge"].select { |point| point["metric"] == "latency.min" }

          assert_equal 1, mins.size
          assert_in_delta 2.0, mins.first["value"]
          assert_equal data["gauge"].size, data["gauge"].map { |point| point["metric"] }.uniq.size
          assert_equal 1, messages.size
          assert_includes messages.first, "latency.min"
        end

        it "leaves out, with a warning, a value beyond the range of a Float" do
          messages = []
          data     = nil
          appender.logger.stub(:warn, ->(message) { messages << message }) do
            data = body(snapshot([:histogram, "huge", 1e308], [:histogram, "huge", 1e308]))
          end
          metrics = (data["counter"] + data["gauge"]).map { |point| point["metric"] }

          assert_includes metrics, "huge.count"
          assert_includes metrics, "huge.max"
          refute_includes metrics, "huge.sum"
          refute_includes metrics, "huge"
          assert_equal 1, messages.size
          assert_includes messages.first, "huge.sum"
        end

        it "warns once for each name beyond the range of a Float, whatever the intervals" do
          messages = []
          appender.logger.stub(:warn, ->(message) { messages << message }) do
            body(snapshot([:histogram, "huge", 1e308], [:histogram, "huge", 1e308]))
            body(snapshot([:histogram, "huge", 1e308], [:histogram, "huge", 1e308]))
            body(snapshot([:histogram, "large", 1e308], [:histogram, "large", 1e308]))
          end

          assert_equal 2, messages.size
          assert_includes messages.last, "large.sum"
          refute_includes messages.last, "huge"
        end

        it "sends the snapshot end time, in ms, as the timestamp of every datapoint" do
          data = body(snapshot([:counter, "jobs", 1], [:histogram, "latency", 0.5, {unit: "s"}]))

          assert_equal [timestamp], (data["counter"] + data["gauge"]).map { |point| point["timestamp"] }.uniq
        end
      end

      describe "as a metric appender" do
        it "has an interval of 60 seconds by default, and of its interval: option" do
          assert_equal 60, appender.metrics_interval
          assert_equal 10, build_appender(interval: 10).metrics_interval
        end

        it "takes no log entries" do
          log        = SemanticLogger::Log.new("User", :info)
          log.metric = "user/login"

          refute appender.should_log?(log)
        end

        it "sends Semantic Logger's own metrics only with internal_metrics: true" do
          aggregator.record(:counter, "users.signup", 1)
          aggregator.record(:counter, "semantic_logger.log.processed", 5, dimensions: {appender: "file"},
                                                                          internal:   true)
          snapshot = aggregator.collect(end_time)

          without = capture_requests { appender.log_metrics(snapshot) }
          internal_appender = build_appender(internal_metrics: true)
          with = capture_requests(internal_appender) { internal_appender.log_metrics(snapshot) }

          assert_equal(["users.signup"], JSON.parse(without.first.body)["counter"].map { |point| point["metric"] })
          assert_equal(%w[users.signup semantic_logger.log.processed],
                       JSON.parse(with.first.body)["counter"].map { |point| point["metric"] })
        end

        it "sends nothing for an empty snapshot" do
          requests = capture_requests do
            appender.log_metrics(aggregator.collect(end_time))
            appender.flush
          end

          assert_empty requests
        end

        it "raises ResponseError when the server rejects the request" do
          response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
          response.instance_variable_set(:@read, true)
          error = appender.http.stub(:request, ->(_request) { response }) do
            assert_raises(SemanticLogger::Appender::Http::ResponseError) do
              appender.write_metrics(snapshot([:counter, "jobs", 1]))
            end
          end

          assert_predicate error, :rejected?
        end

        it "raises ArgumentError for the dimensions: option of Semantic Logger 5" do
          error = assert_raises(ArgumentError) { build_appender(dimensions: %i[region]) }

          assert_includes error.message, "dimensions: option of the :signalfx metric appender was removed"
          assert_includes error.message, "logger.increment(name, dimensions: {...})"
        end

        {
          level:     "whatever the log level",
          filter:    "every metric recorded is written",
          formatter: "the format of its destination"
        }.each_pair do |option, replacement|
          it "refuses #{option}:, which was for the log entries it no longer takes" do
            error = assert_raises(ArgumentError) { build_appender(option => :info) }

            assert_includes error.message, "#{option}:"
            assert_includes error.message, replacement
          end
        end

        it "refuses a formatter block" do
          error = assert_raises(ArgumentError) do
            stub_http_start { SemanticLogger::Metric::Signalfx.new(token: "TEST", &:name) }
          end

          assert_includes error.message, "formatter block"
        end

        it "refuses batch: true" do
          error = assert_raises(ArgumentError) do
            stub_http_start { SemanticLogger::Appender.factory(metric: :signalfx, token: "TEST", batch: true) }
          end

          assert_includes error.message, "nothing to batch"
        end

        it "sends nothing for a snapshot whose series are all left out" do
          requests = appender.logger.stub(:warn, nil) do
            capture_requests { appender.write_metrics(snapshot([:counter, "/", 1])) }
          end

          assert_empty requests
        end

        describe "when writing fails" do
          # A snapshot of the minute from the time, holding the counter "jobs" with the amount.
          def interval(time, amount)
            point = SemanticLogger::Metric::Snapshot::Point.new(kind: :counter, name: "jobs", value: amount)
            SemanticLogger::Metric::Snapshot.new(start_time: time, end_time: time + 60, points: [point])
          end

          # Returns [Array<Integer>] the amount of "jobs" in each request sent for two snapshots, the first
          # answered with the response, the second accepted.
          def sent_after(response)
            response.instance_variable_set(:@read, true)
            first    = interval(start_time, 1)
            second   = interval(end_time, 2)
            requests = []
            answers  = [response, http_success]
            appender.logger.stub(:warn, nil) do
              appender.logger.stub(:error, nil) do
                appender.http.stub(:request, lambda { |request|
                  requests << request
                  answers.shift
                }) do
                  appender.log_metrics(first)
                  appender.log_metrics(second)
                end
              end
            end
            requests.map { |request| JSON.parse(request.body)["counter"].first["value"] }
          end

          it "sends a snapshot that the server asks to send again later with the next one" do
            assert_equal [1, 3], sent_after(Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable"))
          end

          it "discards a snapshot that the server rejects" do
            assert_equal [1, 2], sent_after(Net::HTTPBadRequest.new("1.1", "400", "Bad Request"))
          end

          it "keeps a snapshot that could not be sent, since the server could not be reached" do
            assert appender.metrics_retryable?(Errno::ECONNREFUSED.new)
            refute appender.metrics_retryable?(RuntimeError.new("boom"))
          end
        end
      end

      describe "request" do
        def capture_request(appender)
          requests = capture_requests(appender) { appender.write_metrics(snapshot([:counter, "jobs", 1])) }

          assert_equal 1, requests.size
          requests.first
        end

        it "is added as metric: :splunk_observability, its current name, or :signalfx" do
          %i[splunk_observability signalfx].each do |name|
            appender = stub_http_start { SemanticLogger::Appender.factory(metric: name, token: "TEST", async: false) }

            assert_instance_of SemanticLogger::Metric::Signalfx, appender
          end
        end

        it "posts to the datapoint endpoint, with the token" do
          appender = build_appender(url: "https://ingest.signalfx.com")
          request  = capture_request(appender)

          assert_equal "/#{SemanticLogger::Metric::Signalfx::END_POINT}", appender.full_path
          assert_equal "/#{SemanticLogger::Metric::Signalfx::END_POINT}", request.path
          assert_equal "TEST", request["X-SF-TOKEN"]
          assert_equal "application/json", request["Content-Type"]
        end

        it "appends the datapoint endpoint to the path of the url" do
          appender = build_appender(url: "https://backfill.signalfx.com/v1/backfill")

          assert_equal "/v1/backfill/#{SemanticLogger::Metric::Signalfx::END_POINT}", appender.full_path
        end

        it "keeps a query string of the url at the end of the request uri" do
          appender = build_appender(url: "https://ingest.signalfx.com?orgid=ABC")
          request  = capture_request(appender)

          assert_equal "/#{SemanticLogger::Metric::Signalfx::END_POINT}?orgid=ABC", request.path
        end
      end

      describe "added with add_appender" do
        after do
          SemanticLogger.remove_appender(@added) if @added
        end

        it "sends the metrics of logger calls in one request when flushed" do
          @added = stub_http_start do
            SemanticLogger.add_appender(metric: :signalfx, token: "TEST", host: "web1", application: "shop",
                                        environment: "test")
          end

          assert_instance_of SemanticLogger::Metric::Signalfx, @added

          logger   = SemanticLogger["SignalfxTest"]
          requests = capture_requests(@added) do
            logger.increment("users.signup")
            logger.increment("users.signup", 2, dimensions: {plan: "premium"})
            logger.time("supplier.add_user", duration: 250)
            SemanticLogger.flush
          end

          assert_equal 1, requests.size
          data = JSON.parse(requests.first.body)

          assert_equal(
            [
              ["users.signup", 1, defaults],
              ["users.signup", 2, {"plan" => "premium"}.merge(defaults)],
              ["supplier.add_user.count", 1, defaults],
              ["supplier.add_user.sum", 250.0, defaults]
            ],
            data["counter"].map { |point| [point["metric"], point["value"], point["dimensions"]] }
          )
          assert_equal(%w[supplier.add_user supplier.add_user.min supplier.add_user.max supplier.add_user.p50
                          supplier.add_user.p95 supplier.add_user.p99],
                       data["gauge"].map { |point| point["metric"] })
          assert_in_delta 250.0, data["gauge"].first["value"]
        end
      end
    end
  end
end
