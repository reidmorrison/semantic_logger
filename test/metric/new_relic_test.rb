require_relative "../test_helper"
# So that the NewRelic appender will load the mock
add_mocks_to_load_path

# Unit Test for SemanticLogger::Metric::NewRelic
module Metric
  class NewRelicTest < Minitest::Test
    describe SemanticLogger::Metric::NewRelic do
      let(:appender) { SemanticLogger::Metric::NewRelic.new }
      let(:start_time) { Time.at(1_000) }
      let(:aggregator) { SemanticLogger::Metric::Aggregator.new(now: start_time) }

      # Returns [Array] the calls made to the New Relic agent while the block runs, each [method, name, value].
      def agent_calls(&)
        calls     = []
        increment = ->(name, amount) { calls << [:increment_metric, name, amount] }
        record    = ->(name, value) { calls << [:record_metric, name, value] }
        NewRelic::Agent.stub(:increment_metric, increment) do
          NewRelic::Agent.stub(:record_metric, record, &)
        end
        calls
      end

      # Returns the calls made to the New Relic agent for the snapshot of what the aggregator recorded.
      def written(appender = self.appender)
        snapshot = aggregator.collect(start_time + 60)
        agent_calls { appender.write_metrics(snapshot) }
      end

      # Returns the value given to record_metric for the only histogram written.
      def recorded_value
        calls = written

        assert_equal 1, calls.size
        assert_equal :record_metric, calls.first.first
        calls.first[2]
      end

      it "is a metric appender that takes no log entries" do
        assert_equal 60, appender.metrics_interval
        refute appender.should_log?(SemanticLogger::Log.new("Test", :info))
      end

      it "takes an interval" do
        assert_equal 10, SemanticLogger::Metric::NewRelic.new(interval: 10).metrics_interval
      end

      describe "counters" do
        it "increments by the sum of the amounts" do
          aggregator.record(:counter, "User/authenticated", 1)
          aggregator.record(:counter, "User/authenticated", 4)

          assert_equal [[:increment_metric, "Custom/User/authenticated", 5]], written
        end

        it "increments by a Float sum" do
          aggregator.record(:counter, "Cart/items", 1.5)
          aggregator.record(:counter, "Cart/items", 2)

          assert_equal [[:increment_metric, "Custom/Cart/items", 3.5]], written
        end

        it "increments once per name, by the sum of the series of every dimension set" do
          aggregator.record(:counter, "User/authenticated", 2, dimensions: {region: "us"})
          aggregator.record(:counter, "User/authenticated", 3, dimensions: {region: "eu"})
          aggregator.record(:counter, "User/authenticated", 1)

          assert_equal [[:increment_metric, "Custom/User/authenticated", 6]], written
        end
      end

      describe "histograms" do
        it "records the count, total, min, max, and sum of squares once per interval" do
          aggregator.record(:histogram, "User/authenticate", 0.5, unit: "s")
          aggregator.record(:histogram, "User/authenticate", 2.0, unit: "s")
          calls = written

          assert_equal 1, calls.size
          method, name, value = calls.first

          assert_equal :record_metric, method
          assert_equal "Custom/User/authenticate", name
          assert_equal %i[count total min max sum_of_squares], value.keys
          assert_equal 2, value[:count]
          assert_in_delta 2.5, value[:total]
          assert_in_delta 0.5, value[:min]
          assert_in_delta 2.0, value[:max]
          # Estimated from the midpoints of the buckets of 0.5 and 2.0, each at most 2**(1/8) wide.
          assert_in_delta 4.25, value[:sum_of_squares], 4.25 * 0.1
        end

        it "estimates the sum of squares from the bucket midpoints" do
          values = [1.0, 1.05, 1.1, 1.15, 3.0, 3.1, 3.2, 10.0]
          values.each { |value| aggregator.record(:histogram, "Order/value", value) }
          value = recorded_value
          exact = values.sum { |v| v * v }

          assert_in_delta exact, value[:sum_of_squares], exact * 0.05
        end

        it "records the exact sum of squares of a single value" do
          aggregator.record(:histogram, "Order/value", 2.0)

          assert_in_delta 4.0, recorded_value[:sum_of_squares]
        end

        it "raises an estimate that would imply a negative variance to the least possible" do
          # Both in the bucket (1, 2**(1/8)], narrowed to 1.01..1.08: its midpoint is below the mean.
          aggregator.record(:histogram, "Order/value", 1.01)
          99.times { aggregator.record(:histogram, "Order/value", 1.08) }
          value = recorded_value

          assert_in_delta (value[:total]**2) / value[:count], value[:sum_of_squares]
        end

        it "records durations in seconds" do
          SemanticLogger.add_appender(metric: appender)
          calls = agent_calls do
            SemanticLogger["Metric::NewRelicTest"].time("User/authenticate", duration: 12.5)
            SemanticLogger.flush
          end
          value = calls.first[2]

          assert_in_delta 0.0125, value[:total]
          assert_in_delta 0.0125, value[:min]
          assert_in_delta 0.0125, value[:max]
        ensure
          SemanticLogger.remove_appender(appender)
        end

        it "records once per name, merging the series of every dimension set" do
          aggregator.record(:histogram, "User/authenticate", 1.0, unit: "s", dimensions: {region: "us"})
          aggregator.record(:histogram, "User/authenticate", 3.0, unit: "s", dimensions: {region: "eu"})
          aggregator.record(:histogram, "User/authenticate", 2.0, unit: "s")
          value = recorded_value

          assert_equal 3, value[:count]
          assert_in_delta 6.0, value[:total]
          assert_in_delta 1.0, value[:min]
          assert_in_delta 3.0, value[:max]
          assert_in_delta 14.0, value[:sum_of_squares], 14.0 * 0.1
        end

        it "records a counter and a histogram of the same name each with its own call" do
          # Names that only the prefix makes the same: the Aggregator keeps one kind per name.
          aggregator.record(:counter, "User/login", 1)
          aggregator.record(:histogram, "Custom/User/login", 0.25, unit: "s")

          assert_equal %i[increment_metric record_metric], written.map(&:first).sort
        end
      end

      describe "internal metrics" do
        before do
          aggregator.record(:counter, "semantic_logger.log.processed", 7, dimensions: {appender: "io"}, internal: true)
          aggregator.record(:counter, "User/authenticated", 1)
        end

        # Returns the calls made once the appender is given the snapshot and flushed.
        def logged(appender)
          snapshot = aggregator.collect(start_time + 60)
          agent_calls do
            appender.log_metrics(snapshot)
            appender.flush
          end
        end

        it "leaves them out by default" do
          assert_equal [[:increment_metric, "Custom/User/authenticated", 1]], logged(appender)
        end

        it "records them with internal_metrics: true" do
          appender = SemanticLogger::Metric::NewRelic.new(internal_metrics: true)

          calls = logged(appender).sort_by { |call| call[1] }

          assert_equal [
            [:increment_metric, "Custom/User/authenticated", 1],
            [:increment_metric, "Custom/semantic_logger.log.processed", 7]
          ], calls
        end
      end

      describe "prefix" do
        it "adds the prefix to a name that starts with its letters, but not with it and a slash" do
          assert_equal "Custom/Customers/signup", counted_name(appender, "Customers/signup")
          assert_equal "Custom/CustomerSignup", counted_name(appender, "CustomerSignup")
        end

        it "leaves a name that starts with the prefix and a slash as it is" do
          assert_equal "Custom/User/authenticated", counted_name(appender, "Custom/User/authenticated")
        end

        it "records names with and without the prefix under the one name" do
          aggregator.record(:counter, "Orders/placed", 1)
          aggregator.record(:counter, "Custom/Orders/placed", 2)

          assert_equal [[:increment_metric, "Custom/Orders/placed", 3]], written
        end

        it "uses a prefix given to the subscriber" do
          appender = SemanticLogger::Metric::NewRelic.new(prefix: "App")

          assert_equal "App/Application/boot", counted_name(appender, "Application/boot")
          assert_equal "App/User/authenticated", counted_name(appender, "App/User/authenticated")
        end

        it "adds a prefix given with a trailing slash once" do
          appender = SemanticLogger::Metric::NewRelic.new(prefix: "Custom/")

          assert_equal "Custom", appender.prefix
          assert_equal "Custom/Orders/placed", counted_name(appender, "Orders/placed")
          assert_equal "Custom/Orders/placed", counted_name(appender, "Custom/Orders/placed")
        end

        it "uses a prefix set after the subscriber was added" do
          appender.prefix = "Custom/MyApp/"

          assert_equal "Custom/MyApp", appender.prefix
          assert_equal "Custom/MyApp/Orders/placed", counted_name(appender, "Orders/placed")
          assert_equal "Custom/MyApp/Orders/placed", counted_name(appender, "Custom/MyApp/Orders/placed")
        end

        it "adds nothing with an empty prefix" do
          appender = SemanticLogger::Metric::NewRelic.new(prefix: "")

          assert_equal "User/authenticated", counted_name(appender, "User/authenticated")
        end

        # Returns the name that the appender counts the metric under.
        def counted_name(appender, metric)
          aggregator.record(:counter, metric, 1)
          written(appender).first[1]
        end
      end

      describe "added with add_appender(metric: :new_relic)" do
        let(:logger) { SemanticLogger["Metric::NewRelicTest"] }

        after do
          SemanticLogger.appenders.dup.each do |added|
            SemanticLogger.remove_appender(added) if added.metrics_interval
          end
        end

        it "records the metrics of logger calls when flushed" do
          added = SemanticLogger.add_appender(metric: :new_relic)

          assert_kind_of SemanticLogger::Metric::NewRelic, added
          calls = agent_calls do
            logger.increment("Users/signup", 2)
            logger.time("Supplier/add_user", duration: 250)
            SemanticLogger.flush
          end

          assert_includes calls, [:increment_metric, "Custom/Users/signup", 2]
          record = calls.find { |call| call.first == :record_metric }

          assert_equal "Custom/Supplier/add_user", record[1]
          assert_equal 1, record[2][:count]
          assert_in_delta 0.25, record[2][:total]
        end
      end
    end
  end
end
