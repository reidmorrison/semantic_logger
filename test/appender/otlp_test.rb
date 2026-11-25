require_relative "../test_helper"

module Appender
  class OtlpTest < Minitest::Test
    # The ENV variables that the appender reads, cleared around each test.
    OTEL_ENV = %w[
      OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_LOGS_ENDPOINT OTEL_EXPORTER_OTLP_METRICS_ENDPOINT
      OTEL_SERVICE_NAME OTEL_RESOURCE_ATTRIBUTES
      OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_LOGS_HEADERS OTEL_EXPORTER_OTLP_METRICS_HEADERS
      OTEL_EXPORTER_OTLP_TIMEOUT OTEL_EXPORTER_OTLP_LOGS_TIMEOUT
      OTEL_EXPORTER_OTLP_COMPRESSION OTEL_EXPORTER_OTLP_LOGS_COMPRESSION
      OTEL_EXPORTER_OTLP_PROTOCOL OTEL_EXPORTER_OTLP_LOGS_PROTOCOL OTEL_EXPORTER_OTLP_METRICS_PROTOCOL
      OTEL_EXPORTER_OTLP_CERTIFICATE OTEL_EXPORTER_OTLP_LOGS_CERTIFICATE
    ].freeze

    describe SemanticLogger::Appender::Otlp do
      let(:capture_logger) { SemanticLogger::Test::CaptureLogEvents.new }
      let(:appender) { new_appender(protocol: "http/json") }

      before do
        @saved_env = OTEL_ENV.to_h { |name| [name, ENV.delete(name)] }
      end

      after do
        @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
        # Close the appenders that the test made, so that each unregisters the trace capture.
        @made&.each(&:close)
      end

      def new_appender(**args, &)
        appender = stub_http_start do
          SemanticLogger::Appender::Otlp.stub_any_instance(:logger, capture_logger) do
            SemanticLogger::Appender::Otlp.new(**args, &)
          end
        end
        (@made ||= []) << appender
        appender
      end

      def warnings
        capture_logger.events.select { |event| event.level == :warn }.map(&:message)
      end

      def entry(name, level, message, **args)
        log = SemanticLogger::Log.new(name, level)
        log.time = Time.at(1_700_000_000)
        log.assign(message: message, **args)
        log
      end

      def success(body = "", content_type: nil)
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response.define_singleton_method(:body) { body }
        response["Content-Type"] = content_type if content_type
        response
      end

      # Posts the log entries in one batch, the server answering with the response. Returns the requests.
      def post(logs, on: appender, response: success)
        requests = []
        on.http.stub(:request, lambda { |request|
          requests << request
          response
        }) do
          on.stub(:logger, capture_logger) { on.batch(logs) }
        end
        requests
      end

      def body(logs, on: appender)
        requests = post(logs, on: on)

        assert_equal 1, requests.size
        JSON.parse(requests.first.body)
      end

      it "is added with appender: :otlp, batched" do
        stub_http_start do
          appender = SemanticLogger.add_appender(appender: :otlp)

          assert_instance_of SemanticLogger::Appender::Async, appender
          assert_predicate appender, :batch?
          assert_instance_of SemanticLogger::Appender::Otlp, appender.appender
        ensure
          SemanticLogger.remove_appender(appender)
        end
      end

      it "has the current span captured once per entry, however many :otlp appenders there are" do
        first  = new_appender
        second = new_appender
        plan   = SemanticLogger::SourceCaptures.new([first, second], SemanticLogger::SourceCaptures.generation)

        assert_equal [SemanticLogger::Otlp::TraceContext::CAPTURE], plan.captures
      ensure
        first&.close
        second&.close
      end

      it "makes the capture of the current span shareable, for entries logged in other Ractors" do
        skip "Ractors are not supported" unless defined?(Ractor.shareable?)

        assert Ractor.shareable?(SemanticLogger::Otlp::TraceContext::CAPTURE)
      end

      describe "request" do
        it "posts to http://localhost:4318/v1/logs by default" do
          request = post([entry("A", :info, "hello")]).first

          assert_equal "http://localhost:4318", appender.url
          assert_equal "/v1/logs", request.path
          assert_equal "application/json", request["Content-Type"]
        end

        it "posts http/protobuf by default" do
          protobuf = new_appender
          logs     = [entry("A", :info, "hello")]
          request  = post(logs, on: protobuf).first
          json     = JSON.parse(post(logs).first.body, symbolize_names: true)

          assert_equal "application/x-protobuf", request["Content-Type"]
          assert_equal SemanticLogger::Otlp::Protobuf.encode(json, :ExportLogsServiceRequest), request.body
        end

        it "has the resource of the process" do
          resource = body([entry("A", :info, "hello")]).dig("resourceLogs", 0, "resource", "attributes")
          keys     = resource.map { |attribute| attribute["key"] }

          assert_equal ["service.name", "host.name", "process.pid"], keys - ["deployment.environment.name"]
          assert_includes resource, {"key" => "process.pid", "value" => {"intValue" => Process.pid.to_s}}
        end

        it "has one ScopeLogs for each logger name, in the order of the batch" do
          logs = [
            entry("MyApp::Orders", :info, "one"),
            entry("Rails", :warn, "two"),
            entry("MyApp::Orders", :error, "three")
          ]
          scopes = body(logs).dig("resourceLogs", 0, "scopeLogs")

          assert_equal(%w[MyApp::Orders Rails], scopes.map { |scope| scope.dig("scope", "name") })
          assert_equal(%w[one three], scopes[0]["logRecords"].map { |record| record.dig("body", "stringValue") })
          assert_equal([13], scopes[1]["logRecords"].map { |record| record["severityNumber"] })
        end

        it "posts a single entry as a batch of one" do
          requests = []

          appender.http.stub(:request, lambda { |request|
            requests << request
            success
          }) do
            assert appender.log(entry("A", :info, "hello"))
          end

          assert_equal 1, JSON.parse(requests.first.body).dig("resourceLogs", 0, "scopeLogs").size
        end
      end

      describe "formatter" do
        it "is Formatters::Otlp by default" do
          assert_instance_of SemanticLogger::Formatters::Otlp, appender.formatter
        end

        it "takes a subclass of Formatters::Otlp" do
          subclass = Class.new(SemanticLogger::Formatters::Otlp)

          assert_instance_of subclass, new_appender(formatter: subclass.new).formatter
        end

        it "refuses any other formatter, or a formatter block" do
          error = assert_raises(ArgumentError) { new_appender(formatter: :json) }

          assert_match(/needs a formatter that returns an OTLP LogRecord/, error.message)
          block = ->(log, _appender) { log.message }

          assert_raises(ArgumentError) { new_appender(&block) }
        end

        it "keeps its formatter when a refused one is set" do
          formatter = appender.formatter

          assert_raises(ArgumentError) { appender.formatter = :json }
          assert_same formatter, appender.formatter
        end
      end

      describe "responses" do
        it "reports a JSON partial success" do
          body = {partialSuccess: {rejectedLogRecords: "2", errorMessage: "too big"}}.to_json
          post([entry("A", :info, "hello")], response: success(body, content_type: "application/json"))

          assert_equal 1, warnings.size
          assert_includes warnings.first, "rejected 2 log record(s): \"too big\""
        end

        it "reports a protobuf partial success" do
          body = SemanticLogger::Otlp::Protobuf.encode({partialSuccess: {rejectedLogRecords: 3}},
                                                       :ExportLogsServiceResponse)
          post([entry("A", :info, "hello")], on:       new_appender,
                                             response: success(body, content_type: "application/x-protobuf"))

          assert_includes warnings.first, "rejected 3 log record(s)"
        end

        it "sends a batch again after a 502 or 504, as OTLP/HTTP asks" do
          [502, 504].each do |code|
            assert appender.wrote_nothing?(SemanticLogger::Appender::Http::ResponseError.new("x", code: code))
          end
          refute appender.wrote_nothing?(SemanticLogger::Appender::Http::ResponseError.new("x", code: 500))
        end

        it "takes a record that the binary encoding cannot write as a message error" do
          error = SemanticLogger::Otlp::Protobuf::Error.new("Bad")

          assert appender.message_error?(error)
          refute appender.message_error?(Errno::ECONNREFUSED.new)
        end

        it "discards an entry whose record the binary encoding cannot write" do
          formatter = Class.new(SemanticLogger::Formatters::Otlp) do
            def call(log, logger) = super.merge(color: "red")
          end
          protobuf = new_appender(formatter: formatter.new)

          error = assert_raises(SemanticLogger::Otlp::Protobuf::Error) { post([entry("A", :info, "x")], on: protobuf) }

          assert protobuf.message_error?(error)
        end
      end

      describe "environment variables" do
        it "takes the endpoint from OTEL_EXPORTER_OTLP_LOGS_ENDPOINT, not the metrics one" do
          ENV["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"] = "http://metrics:4318/v1/metrics"
          ENV["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"]    = "http://logs:4318/custom/logs"
          appender = new_appender

          assert_equal "http://logs:4318/custom/logs", appender.url
          assert_equal "/custom/logs", appender.full_path
        end

        it "takes the headers of OTEL_EXPORTER_OTLP_LOGS_HEADERS instead of OTEL_EXPORTER_OTLP_HEADERS" do
          ENV["OTEL_EXPORTER_OTLP_HEADERS"]         = "x-team=core"
          ENV["OTEL_EXPORTER_OTLP_LOGS_HEADERS"]    = "x-logs=yes"
          ENV["OTEL_EXPORTER_OTLP_METRICS_HEADERS"] = "x-metrics=yes"

          assert_equal "yes", appender.header["x-logs"]
          refute appender.header.key?("x-team")
          refute appender.header.key?("x-metrics")
        end

        it "takes the protocol from OTEL_EXPORTER_OTLP_LOGS_PROTOCOL" do
          ENV["OTEL_EXPORTER_OTLP_PROTOCOL"]      = "http/protobuf"
          ENV["OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"] = "http/json"

          assert_equal "http/json", new_appender.protocol.name
        end

        it "warns for grpc, naming the log appender" do
          ENV["OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"] = "grpc"

          assert_equal "http/protobuf", new_appender.protocol.name
          assert_match(%r{OTEL_EXPORTER_OTLP_LOGS_PROTOCOL=grpc: the :otlp log appender sends OTLP/HTTP only},
                       warnings.first)
        end

        it "takes the service name from OTEL_SERVICE_NAME" do
          ENV["OTEL_SERVICE_NAME"] = "checkout"

          assert_equal "checkout", appender.resource_attributes["service.name"]
        end

        it "raises for a certificate file that cannot be read, naming the variable" do
          ENV["OTEL_EXPORTER_OTLP_LOGS_CERTIFICATE"] = "/no/such/file.pem"

          assert_raises(ArgumentError) { new_appender(url: "https://otlp.example.com") }
        end
      end
    end
  end
end
