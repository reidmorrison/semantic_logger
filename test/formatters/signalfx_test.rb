require_relative "../test_helper"
require "net/http"

module SemanticLogger
  module Formatters
    class SignalfxTest < Minitest::Test
      describe SemanticLogger::Formatters::Signalfx do
        let :average_metric_name do
          "Application.average"
        end

        let :counter_metric_name do
          "Application.counter"
        end

        let :log do
          metric     = "/user/login"
          log        = SemanticLogger::Log.new("User", :debug)
          log.metric = metric
          log
        end

        let :logs do
          3.times.collect do |i|
            l        = log.dup
            l.metric = "/user/login#{i + 1}"
            l
          end
        end

        let :same_logs do
          3.times.collect do |_i|
            l        = log.dup
            l.metric = "/user/login"
            l
          end
        end

        let :dimensions do
          {action: "hit", user: "jbloggs", state: "FL"}
        end

        let :all_dimensions do
          dims = dimensions.merge(
            host:        SemanticLogger.host,
            application: SemanticLogger.application,
            environment: "test"
          )
          string_keys = {}
          dims.each_pair { |k, v| string_keys[k.to_s] = v }
          string_keys
        end

        let :appender do
          Net::HTTP.stub_any_instance(:start, true) do
            SemanticLogger::Metric::Signalfx.new(token: "TEST", environment: "test")
          end
        end

        let :formatter do
          appender.formatter
        end

        describe "format single log" do
          let :result do
            JSON.parse(formatter.call(log, appender))
          end

          it "sends a metric whose name is not valid UTF-8" do
            log.metric = (+"/user/log\xFFin").force_encoding(Encoding::UTF_8)

            assert_equal counter_metric_name, result["counter"].first["metric"]
            assert_equal "login", result["counter"].first["dimensions"]["action"]
          end

          it "send counter metric when there is no duration" do
            hash = result

            assert counters = hash["counter"], hash
            assert counter = counters.first, hash
            assert_equal counter_metric_name, counter["metric"], counter
            assert_equal 1, counter["value"], counter
            assert_equal (log.time.to_i * 1_000).to_i, counter["timestamp"], counter
            assert counter.key?("dimensions")
          end

          it "send gauge metric when log includes duration" do
            log.duration = 1234
            hash         = result

            assert counters = hash["gauge"], hash
            assert counter = counters.first, hash
            assert_equal average_metric_name, counter["metric"], counter
            assert_equal 1234, counter["value"], counter
            assert_equal (log.time.to_i * 1_000).to_i, counter["timestamp"], counter
            assert counter.key?("dimensions")
          end

          it "also sends counter metric when gauge metric is sent" do
            log.duration = 1234
            hash         = result

            assert counters = hash["counter"], hash
            assert counter = counters.first, hash
            assert_equal counter_metric_name, counter["metric"], counter
            assert_equal 1, counter["value"], counter
            assert_equal (log.time.to_i * 1_000).to_i, counter["timestamp"], counter
            assert counter.key?("dimensions")
          end

          it "only forwards whitelisted dimensions from named_tags" do
            log.named_tags       = {user_id: 47, tracking_number: 7474, session_id: "hsdhngsd"}
            formatter.dimensions = %i[user_id application]
            hash                 = result

            assert counters = hash["counter"], hash
            assert counter = counters.first, hash
            assert_equal(
              {"class" => "user", "action" => "login", "environment" => "test", "user_id" => "47",
               "host" => SemanticLogger.host, "application" => SemanticLogger.application},
              counter["dimensions"], counter
            )
          end

          it "raises exception with both a whitelist and blacklist" do
            assert_raises ArgumentError do
              SemanticLogger::Formatters::Signalfx.new(token: "TEST", dimensions: [:user_id],
                                                       exclude_dimensions: [:tracking_number])
            end
          end

          it "send custom counter metric when there is no duration" do
            log.metric     = "Filter/count"
            log.dimensions = dimensions
            hash           = result

            assert counters = hash["counter"], hash
            assert counter = counters.first, hash
            assert_equal "Filter.count", counter["metric"], counter
            assert_equal 1, counter["value"], counter
            assert_equal (log.time.to_i * 1_000).to_i, counter["timestamp"], counter
            assert_equal all_dimensions, counter["dimensions"]
          end

          it "sends a duration with dimensions under its own name, without the listed named tags or a count" do
            formatter.dimensions = %i[user_id]
            log.named_tags       = {user_id: 47}
            log.dimensions       = {user: "jbloggs"}
            log.duration         = 12.5
            hash                 = result

            assert gauges = hash["gauge"], hash
            assert_equal 1, gauges.size, hash
            gauge = gauges.first

            assert_equal "user.login", gauge["metric"], gauge
            assert_in_delta 12.5, gauge["value"]
            assert_equal "jbloggs", gauge["dimensions"]["user"], gauge
            refute gauge["dimensions"].key?("user_id"), gauge
            refute hash.key?("counter"), hash
          end
        end

        describe "format batch logs" do
          let :result do
            JSON.parse(formatter.batch(logs, appender))
          end

          it "send metrics" do
            hash = result

            assert counters = hash["counter"], hash
            assert_equal 3, counters.size
            assert_equal counter_metric_name, counters[0]["metric"]
            assert_equal 1, counters[0]["value"]
            assert_equal counter_metric_name, counters[1]["metric"]
            assert_equal counter_metric_name, counters[2]["metric"]
          end

          it "sends gauge metrics" do
            logs.each { |log| log.duration = 3.5 }
            hash = result

            assert gauges = hash["gauge"], hash
            assert_equal 3, gauges.size
            assert_equal average_metric_name, gauges[0]["metric"]
            assert_in_delta(3.5, gauges[0]["value"])
            assert_equal average_metric_name, gauges[1]["metric"]
            assert_equal average_metric_name, gauges[2]["metric"]
          end

          describe "send custom" do
            let :logs do
              3.times.collect do |_i|
                l            = log.dup
                l.metric     = "Filter/count"
                l.dimensions = dimensions
                l
              end
            end

            it "counter metric when there is no duration" do
              hash = result

              assert counters = hash["counter"], hash
              assert counter = counters.first, hash
              assert_equal "Filter.count", counter["metric"], counter
              assert_equal 3, counter["value"], counter
              assert_equal (log.time.to_i * 1_000).to_i, counter["timestamp"], counter
              assert_equal all_dimensions, counter["dimensions"]
            end
          end
        end

        describe "format batch logs with aggregation" do
          let :result do
            JSON.parse(formatter.batch(same_logs, appender))
          end

          it "sends counter metrics" do
            hash = result

            assert counters = hash["counter"], hash
            assert_equal 1, counters.size
            assert_equal counter_metric_name, counters[0]["metric"]
            assert_equal 3, counters[0]["value"]
          end
        end

        # Empty dimensions, such as those of `{supplier: nil}.compact`, are none (see Log#dimensions?): the
        # metric keeps the class and action from its name, the count, and the named tags listed in the
        # formatter's dimensions.
        describe "with empty dimensions" do
          let(:capture) { SemanticLogger::Test::CaptureLogEvents.new }

          let :expected_dimensions do
            {"class" => "user", "action" => "login", "user_id" => "47", "host" => SemanticLogger.host,
             "application" => SemanticLogger.application, "environment" => "test"}
          end

          let(:counter) { {"metric" => counter_metric_name, "value" => 1, "dimensions" => expected_dimensions} }

          before { formatter.dimensions = %i[user_id] }

          # Returns the entries that the block logs to the capturing logger, with the named tag user_id.
          def logged
            SemanticLogger.named_tagged(user_id: 47) { yield capture }
            capture.events
          end

          # Returns the points of the type in the formatted Hash, with only the keys named.
          def points(hash, type, keys = %w[metric value dimensions])
            hash.fetch(type, []).map { |point| point.slice(*keys) }
          end

          it "sends a duration from logger.info as the gauge and the counter" do
            log  = logged { |logger| logger.info(metric: "/user/login", dimensions: {}, duration: 12.5) }.first
            hash = JSON.parse(formatter.call(log, appender))

            gauge = {"metric" => average_metric_name, "value" => 12.5, "dimensions" => expected_dimensions}

            assert_equal [gauge], points(hash, "gauge")
            assert_equal [counter], points(hash, "counter")
          end

          it "sends a count from logger.info as the counter" do
            log  = logged { |logger| logger.info(metric: "/user/login", dimensions: {}) }.first
            hash = JSON.parse(formatter.call(log, appender))

            assert_empty points(hash, "gauge")
            assert_equal [counter], points(hash, "counter")
          end

          it "sends a measure_ duration as the gauge and the counter" do
            log  = logged { |logger| logger.measure_info("Login", metric: "/user/login", dimensions: {}) { nil } }.first
            hash = JSON.parse(formatter.call(log, appender))

            gauge = {"metric" => average_metric_name, "dimensions" => expected_dimensions}

            assert_equal [gauge], points(hash, "gauge", %w[metric dimensions])
            assert_equal [counter], points(hash, "counter")
          end

          it "sends each measure_ duration of a batch as the gauge and the counter" do
            logs = logged do |logger|
              2.times { logger.measure_info("Login", metric: "/user/login", dimensions: {}) { nil } }
            end
            hash = JSON.parse(formatter.batch(logs, appender))

            gauge = {"metric" => average_metric_name, "dimensions" => expected_dimensions}

            assert_equal [gauge] * 2, points(hash, "gauge", %w[metric dimensions])
            # One counter of 2, or one of 1 for each when the entries were logged in different seconds.
            counters = points(hash, "counter", %w[metric dimensions])

            assert_equal [counter.except("value")], counters.uniq
            assert_equal(2, hash["counter"].sum { |point| point["value"] })
          end
        end
      end
    end
  end
end
