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

        it "lets the host, application, and environment of the appender stand over dimensions of those names" do
          data = body(snapshot([:counter, "jobs", 1, {dimensions: {host: "other", region: "east"}}]))

          assert_equal({"counter" => [datapoint("jobs", 1, {"region" => "east"})]}, data)
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
        end
      end

      describe "request" do
        def capture_request(appender)
          requests = capture_requests(appender) { appender.write_metrics(snapshot([:counter, "jobs", 1])) }

          assert_equal 1, requests.size
          requests.first
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
