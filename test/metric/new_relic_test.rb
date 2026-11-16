# So that the NewRelic appender will load the mock
$LOAD_PATH.unshift File.dirname(__FILE__)
require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::NewRelic
module Metric
  class NewRelicTest < Minitest::Test
    describe SemanticLogger::Appender::NewRelic do
      let(:appender) { SemanticLogger::Metric::NewRelic.new }
      let(:amessage) { "AppenderNewRelicTest log message" }

      it "logs counter metric" do
        name = amount = nil
        NewRelic::Agent.stub(:increment_metric, ->(name_, amount_) { name = name_, amount = amount_ }) do
          appender.info(message: amessage, metric: "User/authenticated")
        end

        assert_equal "Custom/User/authenticated", name.first
        assert_equal 1, amount
      end

      it "logs duration metric" do
        name = duration = nil
        NewRelic::Agent.stub(:record_metric, ->(name_, duration_) { name = name_, duration = duration_ }) do
          appender.measure_info(message: amessage, metric: "User/authenticate") do
            sleep 0.001
          end
        end

        assert_equal "Custom/User/authenticate", name.first
        assert duration
      end

      it "counts a metric that has dimensions under its name alone" do
        name = amount = nil
        increment = lambda do |name_, amount_|
          name   = name_
          amount = amount_
        end
        NewRelic::Agent.stub(:increment_metric, increment) do
          appender.info(message: amessage, metric: "User/authenticated", dimensions: {region: "us"})
        end

        assert_equal "Custom/User/authenticated", name
        assert_equal 1, amount
      end

      it "times a metric that has dimensions under its name alone" do
        name = duration = nil
        record = lambda do |name_, duration_|
          name     = name_
          duration = duration_
        end
        NewRelic::Agent.stub(:record_metric, record) do
          appender.info(message: amessage, metric: "User/authenticate", duration: 12.5, dimensions: {region: "us"})
        end

        assert_equal "Custom/User/authenticate", name
        assert_in_delta 0.0125, duration
      end

      describe "prefix" do
        it "adds the prefix to a name that starts with its letters, but not with it and a slash" do
          assert_equal "Custom/Customers/signup", counted_name(appender, "Customers/signup")
          assert_equal "Custom/CustomerSignup", counted_name(appender, "CustomerSignup")
        end

        it "leaves a name that starts with the prefix and a slash as it is" do
          assert_equal "Custom/User/authenticated", counted_name(appender, "Custom/User/authenticated")
        end

        it "uses a prefix given to the subscriber" do
          appender = SemanticLogger::Metric::NewRelic.new(prefix: "App")

          assert_equal "App/Application/boot", counted_name(appender, "Application/boot")
          assert_equal "App/User/authenticated", counted_name(appender, "App/User/authenticated")
        end

        it "adds nothing with an empty prefix" do
          appender = SemanticLogger::Metric::NewRelic.new(prefix: "")

          assert_equal "User/authenticated", counted_name(appender, "User/authenticated")
        end

        # Returns the name that the appender counts the metric under.
        def counted_name(appender, metric)
          name = nil
          NewRelic::Agent.stub(:increment_metric, ->(name_, _amount) { name = name_ }) do
            appender.info(message: amessage, metric: metric)
          end
          name
        end
      end
    end
  end
end
