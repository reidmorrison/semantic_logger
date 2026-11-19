require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Loki
module Appender
  class LokiTest < Minitest::Test
    describe SemanticLogger::Appender::Loki do
      # The appender builds its formatter without structured_metadata:, which keeps pid and thread
      # as labels, with a deprecation warning that test/formatters/loki_test.rb asserts.
      allow_deprecation(/The :loki formatter writes pid and thread as stream labels by default/)

      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }
      let(:log_message) { "AppenderLokiTest log message" }

      it "does not include credentials in the error for a url that cannot be parsed" do
        error = assert_raises(URI::InvalidURIError) do
          SemanticLogger::Appender::Loki.new(url: "https://123456:glc_t0ken pw@logs.example.com")
        end

        assert_includes error.message, "Invalid :url"
        refute_includes error.message, "glc_t0ken"
        assert_nil error.cause
      end

      let(:appender) do
        stub_http_start do
          SemanticLogger::Appender::Loki.new(url: "http://localhost:3100")
        end
      end

      describe "#initialize" do
        it "appends the Loki ingestion path to the url" do
          assert_equal "/#{SemanticLogger::Appender::Loki::INGESTION_PATH}", appender.path
          assert_equal "http://localhost:3100/#{SemanticLogger::Appender::Loki::INGESTION_PATH}", appender.url
        end

        it "allows a custom ingestion path" do
          custom = stub_http_start do
            SemanticLogger::Appender::Loki.new(url: "http://localhost:3100", path: "custom/push")
          end

          assert_equal "/custom/push", custom.path
        end

        it "appends the ingestion path to the path of the url" do
          nested = stub_http_start do
            SemanticLogger::Appender::Loki.new(url: "http://localhost:3100/base/")
          end

          assert_equal "/base/#{SemanticLogger::Appender::Loki::INGESTION_PATH}", nested.path
        end

        it "keeps a query string of the url out of the ingestion path" do
          with_query = stub_http_start do
            SemanticLogger::Appender::Loki.new(url: "http://localhost:3100?orgid=ABC")
          end

          assert_equal "/#{SemanticLogger::Appender::Loki::INGESTION_PATH}", with_query.path
          assert_equal "orgid=ABC", with_query.query
        end

        it "sends the query string of the url with every request" do
          with_query = stub_http_start do
            SemanticLogger::Appender::Loki.new(url: "http://localhost:3100?orgid=ABC")
          end
          request = nil
          with_query.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            with_query.info(log_message)
          end

          assert_equal "/#{SemanticLogger::Appender::Loki::INGESTION_PATH}?orgid=ABC", request.path
        end

        it "uses the Loki formatter by default" do
          assert_instance_of SemanticLogger::Formatters::Loki, appender.formatter
        end

        it "uses the Loki formatter when given a nil formatter" do
          given_nil = stub_http_start do
            SemanticLogger::Appender::Loki.new(url: "http://localhost:3100", formatter: nil)
          end

          assert_instance_of SemanticLogger::Formatters::Loki, given_nil.formatter
        end

        it "restores the Loki formatter when the formatter is set to nil" do
          appender.formatter = :json
          appender.formatter = nil

          assert_instance_of SemanticLogger::Formatters::Loki, appender.formatter
        end

        it "builds the Loki formatter with the limits of a Loki tenant" do
          limits = {max_label_names_per_series: 30, max_label_name_length: 2048, max_label_value_length: 4096}
          raised = Net::HTTP.stub_any_instance(:start, true) do
            SemanticLogger.add_appender(appender: :loki, url: "http://localhost:3100", formatter: {loki: limits})
          end

          assert_equal([30, 2048, 4096], limits.keys.map { |limit| raised.formatter.public_send(limit) })
        ensure
          SemanticLogger.remove_appender(raised)
        end

        it "warns, naming the line that added it, when its formatter is not given structured_metadata:" do
          line     = __LINE__ + 4
          warning  = /loki_test\.rb:#{line}: warning: SemanticLogger: The :loki formatter writes pid/
          appender = assert_deprecated(warning) do
            Net::HTTP.stub_any_instance(:start, true) do
              SemanticLogger.add_appender(appender: :loki, url: "http://localhost:3100")
            end
          end

          assert_empty appender.formatter.structured_metadata
        ensure
          SemanticLogger.remove_appender(appender)
        end

        it "builds the Loki formatter with structured_metadata:, without a warning" do
          appender = refute_deprecated do
            Net::HTTP.stub_any_instance(:start, true) do
              SemanticLogger.add_appender(appender: :loki, url: "http://localhost:3100",
                                          formatter: {loki: {structured_metadata: %i[pid thread]}})
            end
          end

          assert_equal %i[pid thread], appender.formatter.structured_metadata
        ensure
          SemanticLogger.remove_appender(appender)
        end

        it "sets the JSON content type header" do
          assert_equal "application/json", appender.header["Content-Type"]
        end
      end

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, log_message)
          end
          stream = JSON.parse(request.body)["streams"].first

          assert_equal level.to_s, stream["stream"]["level"]
          assert_equal log_message, stream["values"].first[1]
        end

        it "send #{level} exceptions" do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, "Reading File", exc)
          end
          stream  = JSON.parse(request.body)["streams"].first
          payload = stream["values"].first[2]

          assert_equal level.to_s, stream["stream"]["level"]
          assert_equal "NameError", payload["exception_name"]
          assert_match(/undefined local variable or method/, payload["exception_message"])
          assert_includes payload["stack_trace"], __FILE__
        end

        it "send #{level} custom attributes" do
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, log_message, key1: 1, key2: "a")
          end
          stream = JSON.parse(request.body)["streams"].first

          assert_equal level.to_s, stream["stream"]["level"]
          assert_equal log_message, stream["values"].first[1]

          # Loki only accepts strings as payload keys and values.
          payload = stream["values"].first[2]

          assert_equal "1", payload["key1"], payload
          assert_equal "a", payload["key2"], payload
        end
      end

      describe "#batch" do
        it "posts multiple log streams in a single request" do
          logs = [
            SemanticLogger::Log.new("LokiTest", :info),
            SemanticLogger::Log.new("LokiTest", :error)
          ]
          logs[0].message = "first"
          logs[1].message = "second"

          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.batch(logs)
          end

          streams = JSON.parse(request.body)["streams"]

          assert_equal 2, streams.size
          assert_equal "info",   streams[0]["stream"]["level"]
          assert_equal "first",  streams[0]["values"].first[1]
          assert_equal "error",  streams[1]["stream"]["level"]
          assert_equal "second", streams[1]["values"].first[1]
        end

        it "raises an error the appender says the destination caused while Loki is unavailable" do
          log         = SemanticLogger::Log.new("LokiTest", :info)
          log.message = "first"
          unavailable = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
          unavailable.define_singleton_method(:body) { "Ingester is shutting down" }

          error = appender.http.stub(:request, unavailable) do
            assert_raises(SemanticLogger::Appender::Http::ResponseError) { appender.batch([log]) }
          end

          assert_equal 503, error.code
          refute appender.message_error?(error)
        end
      end
    end
  end
end
