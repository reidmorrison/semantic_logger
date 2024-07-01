require_relative "../test_helper"

module Appender
  class SignalfxTest < Minitest::Test
    describe SemanticLogger::Metric::Signalfx do
      let(:metric) { "/user/login" }
      let(:log) do
        log        = SemanticLogger::Log.new("User", :debug)
        log.metric = metric
        log
      end

      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }

      let :appender do
        if ENV["SIGNALFX_TOKEN"]
          SemanticLogger::Metric::Signalfx.new(token: ENV["SIGNALFX_TOKEN"])
        else
          Net::HTTP.stub_any_instance(:start, true) do
            SemanticLogger::Metric::Signalfx.new(token: "TEST")
          end
        end
      end

      describe "log message" do
        let :response do
          # Do not stub if the token is available in the environment
          if ENV["SIGNALFX_TOKEN"]
            appender.log(log)
          else
            appender.http.stub(:request, ->(_request) { http_success }) do
              appender.log(log)
            end
          end
        end

        it "send counter metric when there is no duration" do
          assert response
        end

        it "send custom counter metric when there is no duration" do
          log.metric     = "Filter/count"
          log.dimensions = {action: "hit", user: "jbloggs", state: "FL"}
          assert response
        end

        it "send gauge metric when log includes duration" do
          log.duration = 1234
          assert response
        end

        it "whitelists dimensions" do
          log.named_tags = {user_id: 47, application: "sample", tracking_number: 7474, session_id: "hsdhngsd"}
          appender.formatter.dimensions = %i[user_id application]
          assert response
        end
      end

      describe "should_log?" do
        it "logs metric only metric" do
          assert appender.should_log?(log)
        end

        it "not logs when no metric" do
          log.message = "blah"
          log.metric  = nil
          refute appender.should_log?(log)
        end

        it "logs metric only metric with dimensions" do
          log.metric     = "Filter/count"
          log.dimensions = {action: "hit", user: "jbloggs", state: "FL"}
          assert appender.should_log?(log)
        end
      end
    end
  end
end
