require_relative "../test_helper"
require "bigdecimal"
require "json"

module SemanticLogger
  module Formatters
    class LokiTest < Minitest::Test
      MOCK_LOGGER = Struct.new(:host, :application, :name, :environment)

      describe SemanticLogger::Formatters::Loki do
        let(:log_time) { Time.utc(2017, 1, 14, 8, 32, 5.375276) }
        let(:level) { :debug }
        let(:thread_name) { "thread-#{Thread.current.object_id}" }

        let(:log) do
          l = SemanticLogger::Log.new("LokiTest", level)
          l.time = log_time
          l.thread_name = thread_name
          l.message = "initial message"
          l
        end

        let(:set_exception) do
          raise "Oh no"
        rescue RuntimeError => e
          log.exception = e
        end

        let(:logger) do
          MOCK_LOGGER.new("test_host", "test_app", "TestLogger", "test")
        end

        let(:formatter) do
          SemanticLogger::Formatters::Loki.new
        end

        let(:parsed_output) { JSON.parse(formatter.call(log, logger)) }
        let(:stream_data) { parsed_output["streams"].first["stream"] }
        let(:values_data) { parsed_output["streams"].first["values"].first }

        describe "#call" do
          it "returns a JSON string" do
            assert_kind_of String, formatter.call(log, logger)
          end

          it "has the correct streams structure" do
            assert parsed_output.key?("streams")
            assert_kind_of Array, parsed_output["streams"]
            assert_equal 1, parsed_output["streams"].size
            assert parsed_output["streams"].first.key?("stream")
            assert parsed_output["streams"].first.key?("values")
          end

          it "includes pid in stream" do
            assert_equal Process.pid, stream_data["pid"]
          end

          it "includes host in stream as string" do
            assert_equal "test_host", stream_data["host"]
          end

          it "includes application in stream" do
            assert_equal "test_app", stream_data["application"]
          end

          it "includes environment in stream" do
            assert_equal "test", stream_data["environment"]
          end

          it "includes level in stream" do
            assert_equal "debug", stream_data["level"]
          end

          it "includes thread_name in stream if present" do
            assert_equal thread_name, stream_data["thread"]
          end

          it "includes timestamp in values as nanoseconds string" do
            assert_equal "1484382725375276000", values_data[0]
          end

          it "includes the message" do
            assert_equal "initial message", values_data[1]
          end

          it "includes payload in values as the third element (hash)" do
            log.payload = {data: "sample", number: 123, array: [1, 2, 3]}

            assert_equal(
              {"data" => "sample", "number" => "123", "array" => "[1,2,3]"},
              values_data[2]
            )
          end

          it "serializes nested hashes in the payload as JSON" do
            log.payload = {nested: {number: 1}}

            assert_equal({"nested" => "{\"number\":1}"}, values_data[2])
          end

          it "serializes a nested value once, so that the output grows with the depth, not doubles" do
            nested = "leaf"
            30.times { nested = {"a" => nested} }
            log.payload = {params: nested}

            output = formatter.call(log, logger)
            params = JSON.parse(JSON.parse(output)["streams"][0]["values"][0][2]["params"])

            assert_operator output.bytesize, :<, 2_000
            assert_equal "leaf", params.dig(*["a"] * 30)
          end

          it "writes a payload that is not a Hash as a single field" do
            log.payload = "just a string"

            assert_equal({"payload" => "just a string"}, values_data[2])
          end

          it "writes a Struct as JSON of its members, not its #inspect" do
            client      = Class.new { def initialize = (@password = "hunter2") }.new
            log.payload = {client: Struct.new(:name, :api).new("billing", client), list: [client]}

            refute_includes formatter.call(log, logger), "hunter2"
            assert_equal "billing", JSON.parse(values_data[2]["client"])["name"]
          end

          it "does not raise for a message with invalid UTF-8" do
            log.message = (+"Search: \e\xFF").force_encoding(Encoding::UTF_8)

            assert_equal "Search:", values_data[1]
          end

          describe "when log application is true" do
            let(:formatter) do
              Loki.new(log_application: false)
            end

            it "omits application in stream when log_application is false" do
              refute parsed_output["streams"].first["stream"].key?("application")
            end
          end

          describe "when logger.application is nil" do
            let(:formatter) { Loki.new(log_application: false) }
            let(:logger) { MOCK_LOGGER.new("test_host", nil, "TestLogger", "test") }

            it "omits application in stream when log_application is false" do
              refute parsed_output["streams"].first["stream"].key?("application")
            end
          end

          describe "when thread_name is nil" do
            it "omits from the stream" do
              log.thread_name = nil

              refute stream_data.key?("thread")
            end
          end

          describe "when tags is present" do
            it "adds to the stream" do
              log.tags = [:test1, "test2"]

              assert_equal %w[test1 test2], stream_data["tags"]
            end
          end

          describe "when tags is nil" do
            it "omits from the steam" do
              log.tags = nil

              refute stream_data.key?("tags")
            end
          end

          describe "when named_tags is present" do
            it "adds to the stream" do
              log.named_tags = {key1: "value1", key2: "value2"}

              assert_equal "value1", stream_data["key1"]
              assert_equal "value2", stream_data["key2"]
            end
          end

          describe "when named_tags is nil" do
            it "omits from the stream" do
              log.named_tags = nil

              refute stream_data.key?("key1")
              refute stream_data.key?("key2")
            end
          end

          describe "when named_tags is empty" do
            it "omits from the stream" do
              log.named_tags = {}

              refute stream_data.key?("key1")
              refute stream_data.key?("key2")
            end
          end

          describe "when a value is nil" do
            it "leaves out a named tag" do
              log.named_tags = {tenant: nil, user: "jack"}

              refute stream_data.key?("tenant")
              assert_equal "jack", stream_data["user"]
            end

            it "leaves out a value of the context" do
              log.context = {request_id: nil}

              refute stream_data.key?("request_id")
            end

            it "leaves out the host" do
              logger = MOCK_LOGGER.new(nil, "test_app", "TestLogger", "test")

              refute JSON.parse(formatter.call(log, logger))["streams"][0]["stream"].key?("host")
            end
          end

          it "writes a named tag or context value that is not a String as Loki stores it" do
            log.named_tags = {count: 42, admin: true, plan: :gold, filter: {a: 1}, ids: [1, "a"]}
            log.context    = {retries: 2}

            assert_equal ["42", "true", "gold", "{\"a\":1}", "[1,\"a\"]", "2"],
                         stream_data.values_at("count", "admin", "plan", "filter", "ids", "retries")
          end

          # Loki rejects the whole push, with "couldn't parse labels", for any other label name.
          describe "when a named tag or context key is not a label name Loki accepts" do
            # Raises for a label written twice, of which Loki keeps only the last value.
            let(:labels) do
              JSON.parse(formatter.call(log, logger), allow_duplicate_key: false)["streams"][0]["stream"]
            end

            it "replaces each character that Loki does not accept with an underscore" do
              log.named_tags = {"request-id": "a", "a.b c" => "b"}

              assert_equal "a", labels["request_id"]
              assert_equal "b", labels["a_b_c"]
              refute labels.key?("request-id")
            end

            it "writes two or more underscores in a row as one, as Loki writes structured metadata names" do
              log.named_tags = {"a--b" => "a", "c-_d" => "b"}

              assert_equal "a", labels["a_b"]
              assert_equal "b", labels["c_d"]
            end

            it "prefixes a name that would start with a digit, and an empty name" do
              log.named_tags = {"1st" => "a", "" => "b", 2 => "c"}

              assert_equal %w[a b c], labels.values_at("key_1st", "key_", "key_2")
            end

            it "replaces a key outside ASCII as it is written, without invalid bytes" do
              log.named_tags = {"région" => "a", "\xFFid".b.force_encoding(Encoding::UTF_8) => "b"}

              assert_equal "a", labels["r_gion"]
              assert_equal "b", labels["id"]
            end

            it "keeps a name that Loki accepts" do
              log.named_tags = {"_x" => "a", "Ab_9" => "b", "a__b" => "c", :sym => "d"}

              assert_equal %w[a b c d], labels.values_at("_x", "Ab_9", "a__b", "sym")
            end

            it "replaces a key of the context" do
              log.context = {"trace-id" => "abc"}

              assert_equal "abc", labels["trace_id"]
            end

            it "numbers a replaced name that another label has, keeping both values" do
              log.named_tags = {"request-id": "a", request_id: "b", "request.id": "c"}

              assert_equal %w[b a c], labels.values_at("request_id", "request_id_2", "request_id_3")
            end

            it "numbers a replaced key of the context that a named tag has" do
              log.named_tags = {request_id: "a"}
              log.context    = {"request-id" => "b"}

              assert_equal %w[a b], labels.values_at("request_id", "request_id_2")
            end

            it "writes a replaced name once when another label has the same name and value" do
              log.named_tags = {"request-id": "abc", request_id: "abc"}

              assert_equal "abc", labels["request_id"]
              refute labels.key?("request_id_2")
            end

            it "writes a replaced name once when another label has the same value as another type" do
              log.named_tags = {request_id: "1", "request-id": 1}

              assert_equal "1", labels["request_id"]
              refute labels.key?("request_id_2")
            end

            it "writes a replaced name once when one of its own labels has the same value" do
              log.named_tags = {"\xFFlevel".b.force_encoding(Encoding::UTF_8) => "debug"}

              assert_equal "debug", labels["level"]
              refute labels.key?("level_2")
            end
          end

          # Loki keeps only the last value of a label written twice.
          describe "when a named tag or context key has the name of another label" do
            # Raises for a label written twice.
            let(:labels) do
              JSON.parse(formatter.call(log, logger), allow_duplicate_key: false)["streams"][0]["stream"]
            end

            it "keeps the names of its own labels, and numbers a named tag with one of them" do
              log.tags       = %w[a b]
              log.named_tags = {
                :pid          => 1,
                "application" => "other_app",
                :environment  => "staging",
                :host         => "other_host",
                "level"       => "warn",
                :thread       => "worker",
                :tags         => "c"
              }

              assert_equal(
                [Process.pid, "test_app", "test", "test_host", "debug", thread_name, %w[a b]],
                labels.values_at("pid", "application", "environment", "host", "level", "thread", "tags")
              )
              assert_equal(
                %w[1 other_app staging other_host warn worker c],
                labels.values_at(*%w[pid application environment host level thread tags].map { |name| "#{name}_2" })
              )
            end

            it "numbers a key of the context with the name of one of its own labels" do
              log.context = {host: "other_host"}

              assert_equal %w[test_host other_host], labels.values_at("host", "host_2")
            end

            it "numbers a key of the context with the name of a named tag" do
              log.named_tags = {request_id: "a"}
              log.context    = {request_id: "b"}

              assert_equal %w[a b], labels.values_at("request_id", "request_id_2")
            end

            it "numbers a named tag given both as a Symbol and as a String" do
              log.named_tags = {request_id: "a", "request_id" => "b"}

              assert_equal %w[a b], labels.values_at("request_id", "request_id_2")
            end

            it "writes it once when the other label has the same value, as Loki stores it" do
              log.tags       = %w[a b]
              log.named_tags = {"host" => "test_host", "level" => :debug, "pid" => Process.pid.to_s, "tags" => %w[a b]}
              log.context    = {"host" => "test_host", :level => "debug"}

              assert_equal(
                {
                  "pid"         => Process.pid,
                  "application" => "test_app",
                  "environment" => "test",
                  "host"        => "test_host",
                  "level"       => "debug",
                  "thread"      => thread_name,
                  "tags"        => %w[a b]
                },
                labels
              )
            end

            it "writes a value of the context once when a named tag has it" do
              log.named_tags = {request_id: "abc"}
              log.context    = {"request_id" => "abc"}

              assert_equal "abc", labels["request_id"]
              refute labels.key?("request_id_2")
            end
          end

          describe "when message is nil" do
            it "includes empty string for message" do
              log.message = nil

              assert_equal "", values_data[1]
            end
          end

          describe "when payload is nil" do
            it "includes empty hash for payload" do
              log.payload = nil

              assert_equal({}, values_data[2])
            end
          end

          describe "when payload is empty hash" do
            it "includes empty hash for payload" do
              log.payload = {}

              assert_equal({}, values_data[2])
            end
          end

          describe "when context is present" do
            it "includes empty hash for payload" do
              log.context = {test: "string", hash: {value: "1"}}

              assert_equal "string", stream_data["test"]
              assert_equal "{\"value\":\"1\"}", stream_data["hash"]
            end

            it "leaves out what an appender captured for its own use" do
              log.context = {request_id: "abc"}
              log.capture(:open_telemetry, Object.new)
              log.capture(:new_relic_metadata, {"trace.id" => "trace123"})

              assert_equal "abc", stream_data["request_id"]
              refute stream_data.key?("open_telemetry")
              refute stream_data.key?("new_relic_metadata")
            end
          end

          describe "when context is empty" do
            it "keeps the existing keys on the stream" do
              log.context = {}

              expected_keys = %w[
                pid
                application
                environment
                host
                level
                thread
              ]

              assert_equal(expected_keys, stream_data.keys)
            end
          end

          describe "when context is nil" do
            it "keeps the existing keys on the stream" do
              log.context = nil

              expected_keys = %w[
                pid
                application
                environment
                host
                level
                thread
              ]

              assert_equal(expected_keys, stream_data.keys)
            end
          end

          it "includes metric in payload part of values if present" do
            log.metric = "my_metric"
            log.metric_amount = 100

            payload_obj = values_data[2]

            assert_equal "my_metric", payload_obj["metric"]
            assert_equal "100", payload_obj["metric_value"]
          end

          # Loki rejects the whole push, with every entry in it, for a value that is not a String.
          it "writes the metric's amount as a String" do
            log.metric        = :my_metric
            log.metric_amount = 1.5

            assert_equal "my_metric", values_data[2]["metric"]
            assert_equal "1.5", values_data[2]["metric_value"]
          end

          # LogQL cannot read a Rational's own text, `3/2`, so every query that unwraps it would fail.
          it "writes a Rational or BigDecimal amount as a decimal number" do
            log.metric        = "my_metric"
            log.metric_amount = Rational(3, 2)

            assert_equal "1.5", values_data[2]["metric_value"]

            log.metric_amount = BigDecimal("2.5")

            assert_equal "2.5", JSON.parse(formatter.call(log, logger))["streams"][0]["values"][0][2]["metric_value"]
          end

          it "omits metric_value for a metric without an amount" do
            log.metric = "my_metric"

            assert_equal({"metric" => "my_metric"}, values_data[2])
          end

          it "includes the metric's dimensions as a single JSON value" do
            log.metric     = "my_metric"
            log.dimensions = {region: "us", tier: 2}

            assert_equal({"region" => "us", "tier" => 2}, JSON.parse(values_data[2]["dimensions"]))
          end

          it "omits dimensions without a metric" do
            log.dimensions = {region: "us"}

            refute values_data[2].key?("dimensions")
          end

          it "merges metric with existing payload" do
            log.payload = {data: "sample"}
            log.metric = "my_metric"
            log.metric_amount = 100

            payload_obj = values_data[2]

            assert_equal "sample", payload_obj["data"]
            assert_equal "my_metric", payload_obj["metric"]
            assert_equal "100", payload_obj["metric_value"]
          end

          describe "when duration is present" do
            it "includes duration" do
              log.duration = 123.456
              log.stub(:duration_human, "123.46ms") do
                payload_obj = values_data[2]

                assert_equal "123.456", payload_obj["duration"]
                assert_equal "123.46ms", payload_obj["duration_human"]
              end
            end

            it "writes an Integer as it is, and a Rational or BigDecimal as a decimal number" do
              durations = [5, Rational(5, 2), BigDecimal("0.5")].map do |duration|
                log.duration = duration
                JSON.parse(formatter.call(log, logger))["streams"][0]["values"][0][2]["duration"]
              end

              assert_equal %w[5 2.5 0.5], durations
            end
          end

          describe "when duration is nil" do
            it "omits duration and duration_human" do
              log.duration = nil
              payload_obj = values_data[2]

              refute payload_obj.key?("duration")
              refute payload_obj.key?("duration_human")
            end
          end

          it "includes exception in payload part of values if present" do
            set_exception

            payload_obj = values_data[2]

            assert_equal "RuntimeError", payload_obj["exception_name"]
            assert_equal "Oh no", payload_obj["exception_message"]
            assert_kind_of String, payload_obj["stack_trace"]
          end

          it "writes one line per frame, not an inspected Array" do
            set_exception
            log.exception.set_backtrace(["app/a.rb:1:in 'A#a'", "app/b.rb:2:in 'B#b'"])

            assert_equal "app/a.rb:1:in 'A#a'\napp/b.rb:2:in 'B#b'", values_data[2]["stack_trace"]
          end

          it "includes the backtrace of each exception that caused it" do
            begin
              begin
                raise ArgumentError, "inner"
              rescue ArgumentError => e
                e.set_backtrace(%w[i1 i2])
                raise "outer"
              end
            rescue RuntimeError => e
              e.set_backtrace(%w[o1])
              log.exception = e
            end

            assert_equal "o1\nCause: ArgumentError: inner\ni1\ni2", values_data[2]["stack_trace"]
          end

          it "escapes the stack trace when control characters are escaped" do
            begin
              begin
                raise ArgumentError, "in\nner"
              rescue ArgumentError => e
                e.set_backtrace(["i1\e[2J"])
                raise "outer"
              end
            rescue RuntimeError => e
              e.set_backtrace(%w[o1])
              log.exception = e
            end
            formatter = SemanticLogger::Formatters::Loki.new(escape_control_chars: true)
            values    = JSON.parse(formatter.call(log, logger))["streams"].first["values"].first

            assert_equal "o1\nCause: ArgumentError: in\\nner\ni1\\e[2J", values[2]["stack_trace"]
          end

          it "writes the stack trace when the #message of an exception that caused it raises" do
            begin
              begin
                raise ExceptionFixtures::BrokenMessageError, "Order 7"
              rescue ExceptionFixtures::BrokenMessageError => e
                e.set_backtrace(%w[i1])
                raise "outer"
              end
            rescue RuntimeError => e
              e.set_backtrace(%w[o1])
              log.exception = e
            end

            assert_equal "o1\nCause: ExceptionFixtures::BrokenMessageError: Order 7\ni1", values_data[2]["stack_trace"]
          end

          it "names an exception that caused it of an anonymous class as it names the exception" do
            cause_class = Class.new(StandardError)
            begin
              begin
                raise cause_class, "inner"
              rescue cause_class => e
                e.set_backtrace(%w[i1])
                raise "outer"
              end
            rescue RuntimeError => e
              e.set_backtrace(%w[o1])
              log.exception = e
            end

            assert_equal "o1\nCause: #{cause_class}: inner\ni1", values_data[2]["stack_trace"]
          end

          it "writes an empty stack trace for an exception that was never raised" do
            log.exception = RuntimeError.new("Not raised")

            assert_equal "", values_data[2]["stack_trace"]
          end

          it "merges exception with existing payload and metric" do
            log.payload = {data: "sample"}
            log.metric = "my_metric"
            log.metric_amount = 100
            set_exception

            payload_obj = values_data[2]

            assert_equal "sample", payload_obj["data"]
            assert_equal "my_metric", payload_obj["metric"]
            assert_equal "100", payload_obj["metric_value"]
            assert_equal "RuntimeError", payload_obj["exception_name"]
          end

          it "names an exception by its class's name, as :json does, rather than the class's #to_s" do
            error_class = Class.new(StandardError) do
              def self.name = "Payments::Declined"
              def self.to_s = "custom"
            end
            log.exception = error_class.new("Declined")

            assert_equal "Payments::Declined", values_data[2]["exception_name"]
          end

          it "names an exception of an anonymous class as the text formatters do" do
            log.exception = Class.new(StandardError).new("Oh no")

            assert_match(/\A#<Class:0x\h+>\z/, values_data[2]["exception_name"])
            assert_equal "Oh no", values_data[2]["exception_message"]
          end

          it "writes an empty message for an exception whose message is nil" do
            log.exception = Class.new(StandardError) { def message = nil }.new

            assert_equal "", values_data[2]["exception_message"]
          end

          it "writes every value of the structured metadata as a String" do
            log.payload       = {data: nil, number: 1, flag: true}
            log.metric        = :my_metric
            log.metric_amount = 3
            log.dimensions    = {tier: 2}
            log.duration      = 1.5
            log.exception     = Class.new(StandardError) { def message = nil }.new

            assert_empty(values_data[2].values.reject { |value| value.is_a?(String) })
          end

          describe "when a payload key is named like one of its own" do
            # Raises for a key written twice, of which Loki keeps only the last value.
            let(:structured_metadata) do
              JSON.parse(formatter.call(log, logger), allow_duplicate_key: false)["streams"][0]["values"][0][2]
            end

            it "prefixes the payload's metric keys" do
              log.metric        = "my_metric"
              log.metric_amount = 3
              log.dimensions    = {region: "us"}
              log.payload       = {"metric" => "a", :metric_value => "b", "dimensions" => "10x20"}

              assert_equal(
                {
                  "payload_metric"       => "a",
                  "payload_metric_value" => "b",
                  "payload_dimensions"   => "10x20",
                  "metric"               => "my_metric",
                  "metric_value"         => "3",
                  "dimensions"           => "{\"region\":\"us\"}"
                },
                structured_metadata
              )
            end

            it "prefixes the payload's duration keys" do
              log.duration = 1.5
              log.payload  = {duration: "PT5S", "duration_human" => "five seconds"}

              assert_equal "1.5", structured_metadata["duration"]
              assert_equal "PT5S", structured_metadata["payload_duration"]
              assert_equal "five seconds", structured_metadata["payload_duration_human"]
            end

            it "prefixes the payload's exception keys" do
              log.exception = RuntimeError.new("Oh no")
              names         = %w[exception_name exception_message stack_trace]
              log.payload   = names.zip(%w[a b c]).to_h

              assert_equal "RuntimeError", structured_metadata["exception_name"]
              assert_equal "Oh no", structured_metadata["exception_message"]
              assert_equal "", structured_metadata["stack_trace"]
              assert_equal %w[a b c], structured_metadata.values_at(*names.map { |name| "payload_#{name}" })
            end

            it "prefixes it when the entry does not have that field, so that the name always means the same" do
              log.payload = {"duration" => "PT5S", "metric" => "a"}

              assert_equal({"payload_duration" => "PT5S", "payload_metric" => "a"}, structured_metadata)
            end

            # Loki stores each of these as `metric_value`, and would keep one value of them.
            it "prefixes a key that Loki would store under one of its own names, under the name it stores" do
              log.metric        = "my_metric"
              log.metric_amount = 3
              zero_width        = "metric#{0x200B.chr(Encoding::UTF_8)}value"
              log.payload       = ["metric.value", "metric__value", "metric-value", zero_width].zip(%w[a b c d]).to_h

              assert_equal(
                {
                  "metric"                                       => "my_metric",
                  "metric_value"                                 => "3",
                  "payload_metric_value"                         => "a",
                  "payload_payload_metric_value"                 => "b",
                  "payload_payload_payload_metric_value"         => "c",
                  "payload_payload_payload_payload_metric_value" => "d"
                },
                structured_metadata
              )
            end

            # So that a query on `payload_metric_value` reads the payload's `metric_value`.
            it "prefixes again a lookalike of a key that is exactly one of its own, whatever their order" do
              expected = {"payload_metric_value" => "exact", "payload_payload_metric_value" => "lookalike"}
              log.payload = {"metric.value" => "lookalike", "metric_value" => "exact"}

              assert_equal expected, structured_metadata

              log.payload = {"metric_value" => "exact", "metric.value" => "lookalike"}

              assert_equal expected, JSON.parse(formatter.call(log, logger))["streams"][0]["values"][0][2]
            end

            # Loki stores `payload.metric` as `payload_metric`.
            it "prefixes again a key that a key of the payload is stored as once Loki changes its name" do
              log.payload = {"payload.metric" => "x", "metric" => "y"}

              assert_equal({"payload.metric" => "x", "payload_payload_metric" => "y"}, structured_metadata)
            end

            it "compares a key with invalid UTF-8 as it is written, without the invalid bytes" do
              log.payload = {
                "metric\xFF".b.force_encoding(Encoding::UTF_8)      => "a",
                "metric\xFFvalue".b.force_encoding(Encoding::UTF_8) => "b"
              }

              assert_equal({"payload_metric" => "a", "metricvalue" => "b"}, structured_metadata)
            end

            it "prefixes a key in an encoding that is not ASCII-compatible" do
              log.payload = {"metric".encode(Encoding::UTF_16LE) => "a"}

              assert_equal({"payload_metric" => "a"}, structured_metadata)
            end

            it "keeps other keys as they are" do
              log.metric  = "my_metric"
              log.payload = {"Metric" => "a", "metrics" => "b", "_metric" => "c", "metric_" => "d", "payload_x" => "e"}

              assert_equal log.payload.merge("metric" => "my_metric"), structured_metadata
            end

            it "prefixes it again when the payload already has the prefixed key" do
              log.payload = {"metric" => "a", "payload_metric" => "b"}

              assert_equal({"payload_metric" => "b", "payload_payload_metric" => "a"}, structured_metadata)
            end

            it "names every field that the formatter writes itself" do
              log.metric        = "my_metric"
              log.metric_amount = 3
              log.dimensions    = {region: "us"}
              log.duration      = 1.5
              set_exception

              assert_equal Loki::OWN_KEYS.sort, structured_metadata.keys.sort
            end
          end

          # Loki rejects the whole push for it, with "label name is empty", or "normalization for label
          # name "-" resulted in invalid name "_"".
          describe "when a payload key has no ASCII letter or digit" do
            let(:structured_metadata) do
              JSON.parse(formatter.call(log, logger), allow_duplicate_key: false)["streams"][0]["values"][0][2]
            end

            it "prefixes an empty key" do
              log.payload = {"" => "a", "user" => "jack"}

              assert_equal({"user" => "jack", "payload_" => "a"}, structured_metadata)
            end

            it "prefixes a key of other characters, as Loki stores it" do
              log.payload = {"-" => "a"}

              assert_equal({"payload_" => "a"}, structured_metadata)
            end

            # jQuery adds `_` to the parameters of a request it keeps from being cached.
            it "prefixes an underscore" do
              log.payload = {"_" => "1700000000000"}

              assert_equal({"payload_" => "1700000000000"}, structured_metadata)
            end

            # Loki stores each of them as `payload_` once prefixed, and would keep one value of them.
            it "prefixes again each key that the others are stored as" do
              log.payload = {"" => "a", "-" => "b", "_" => "c"}

              assert_equal(
                {"payload_" => "a", "payload_payload_" => "b", "payload_payload_payload_" => "c"},
                structured_metadata
              )
            end

            it "prefixes a key of invalid bytes, which is written as an empty key" do
              log.payload = {"\xFF".b.force_encoding(Encoding::UTF_8) => "a"}

              assert_equal({"payload_" => "a"}, structured_metadata)
            end
          end

          # Issue #180: .to_json raises Encoding::UndefinedConversionError on non UTF-8 data.
          it "serializes non UTF-8 data without raising" do
            log.message    = "Bad: \xE2".b
            log.tags       = ["Tag: \xE2".b]
            log.named_tags = {"name\xE2".b => "val\xE2".b}
            log.payload    = {"key\xE2".b => "value\xE2".b}

            assert_equal "Bad:", values_data[1]
            assert_equal ["Tag: "], stream_data["tags"]
            assert_equal "val", stream_data["name"]
            assert_equal "value", values_data[2]["key"]
          end
        end

        describe "#batch" do
          let(:log2) do
            l = SemanticLogger::Log.new("LokiTest2", :info)
            l.time = log_time + 10 # Different time
            l.thread_name = "other-thread"
            l.message = "Second message"
            l
          end
          let(:logs) { [log, log2] }
          let(:parsed_batch_output) { JSON.parse(formatter.batch(logs, logger)) }

          it "returns a JSON string" do
            assert_kind_of String, formatter.batch(logs, logger)
          end

          it "has the correct streams structure for batch" do
            assert parsed_batch_output.key?("streams")
            assert_kind_of Array, parsed_batch_output["streams"]
            assert_equal 2, parsed_batch_output["streams"].size
          end

          it "formats each log entry correctly in batch" do
            stream1_data = parsed_batch_output["streams"][0]["stream"]
            values1_data = parsed_batch_output["streams"][0]["values"][0]
            stream2_data = parsed_batch_output["streams"][1]["stream"]
            values2_data = parsed_batch_output["streams"][1]["values"][0]

            assert_equal Process.pid, stream1_data["pid"]
            assert_equal "debug", stream1_data["level"]
            assert_equal thread_name, stream1_data["thread"]
            assert_equal "1484382725375276000", values1_data[0]
            assert_equal "initial message", values1_data[1]

            assert_equal Process.pid, stream2_data["pid"]
            assert_equal "info", stream2_data["level"]
            assert_equal "other-thread", stream2_data["thread"]
            assert_equal "1484382735375276000", values2_data[0]
            assert_equal "Second message", values2_data[1]
          end
        end
      end
    end
  end
end
