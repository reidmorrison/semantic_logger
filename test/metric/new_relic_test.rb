# So that the NewRelic appender will load the mock
$LOAD_PATH.unshift File.dirname(__FILE__)
require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::NewRelic
module Metric
  class NewRelicTest < Minitest::Test
    describe SemanticLogger::Appender::NewRelic do
      before do
        @appender = SemanticLogger::Metric::NewRelic.new
        @message  = "AppenderNewRelicTest log message"
      end

      it "logs counter metric" do
        name = amount = nil
        NewRelic::Agent.stub(:increment_metric, ->(name_, amount_) { name = name_, amount = amount_ }) do
          @appender.info(message: @message, metric: "User/authenticated")
        end
        assert_equal "Custom/User/authenticated", name.first
        assert_equal 1, amount
      end

      it "logs duration metric" do
        name = duration = nil
        NewRelic::Agent.stub(:record_metric, ->(name_, duration_) { name = name_, duration = duration_ }) do
          @appender.measure_info(message: @message, metric: "User/authenticate") do
            sleep 0.001
          end
        end
        assert_equal "Custom/User/authenticate", name.first
        assert duration
      end
    end
  end
end
