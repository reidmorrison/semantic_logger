require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class JsonTest < Minitest::Test
      describe Json do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          log      = SemanticLogger::Log.new("JsonTest", level)
          log.time = log_time
          log
        end

        let(:appender) do
          Struct.new(:host, :application, :environment).new("test_host", "test_app", "test_env")
        end

        let(:formatter) do
          SemanticLogger::Formatters::Json.new
        end

        let(:parsed) do
          JSON.parse(formatter.call(log, appender))
        end

        describe "trace" do
          let(:trace_id) { "5b8efff798038103d269b633813fc60c" }
          let(:span_id) { "eee19b7ec3c1b174" }

          it "is written by this formatter, so it returns its capture for its appender" do
            assert_equal SemanticLogger::Otlp::TraceContext::CAPTURES, formatter.source_captures
          end

          it "writes the ids and flags of the span that was current when the entry was logged" do
            log.capture(SemanticLogger::Otlp::TraceContext::KEY, [trace_id, span_id, 1])

            assert_equal trace_id, parsed["trace_id"]
            assert_equal span_id, parsed["span_id"]
            assert_equal "01", parsed["trace_flags"]
          end

          it "writes flags of 00 for a span that is not sampled" do
            log.capture(SemanticLogger::Otlp::TraceContext::KEY, [trace_id, span_id, 0])

            assert_equal "00", parsed["trace_flags"]
          end

          it "writes the trace_id and span_id named tags without flags, and keeps the named tags" do
            log.named_tags = {trace_id: trace_id.upcase, span_id: span_id, user: "joe"}

            assert_equal trace_id, parsed["trace_id"]
            assert_equal span_id, parsed["span_id"]
            refute parsed.key?("trace_flags")
            assert_equal({"trace_id" => trace_id.upcase, "span_id" => span_id, "user" => "joe"}, parsed["named_tags"])
          end

          it "writes the trace without a span_id named tag that is not a span id" do
            log.named_tags = {trace_id: trace_id, span_id: "123"}

            assert_equal trace_id, parsed["trace_id"]
            refute parsed.key?("span_id")
          end

          it "writes it from a subclass that replaces named_tags" do
            subclass = Class.new(SemanticLogger::Formatters::Json) do
              def named_tags
                hash[:labels] = log.named_tags
              end
            end
            log.capture(SemanticLogger::Otlp::TraceContext::KEY, [trace_id, span_id, 1])

            assert_equal trace_id, JSON.parse(subclass.new.call(log, appender))["trace_id"]
          end

          it "leaves a trace_id that a subclass wrote" do
            subclass = Class.new(SemanticLogger::Formatters::Json) do
              def payload
                hash[:trace_id] = "from-subclass"
              end
            end
            log.capture(SemanticLogger::Otlp::TraceContext::KEY, [trace_id, span_id, 1])

            parsed = JSON.parse(subclass.new.call(log, appender))

            assert_equal "from-subclass", parsed["trace_id"]
            refute parsed.key?("span_id")
            refute parsed.key?("trace_flags")
          end

          it "writes no trace for an entry logged outside one" do
            log.named_tags = {trace_id: "abc"}

            refute(parsed.keys.any? { |key| key.start_with?("trace_", "span_") })
          end
        end

        it "returns a JSON string" do
          result = formatter.call(log, appender)

          assert_kind_of String, result
          assert JSON.parse(result)
        end

        it "uses :timestamp as the default time key" do
          assert parsed.key?("timestamp")
          refute parsed.key?("time")
        end

        it "formats the time as iso_8601 by default" do
          assert_equal "2017-01-14T08:32:05.375276Z", parsed["timestamp"]
        end

        it "honours a custom time_key" do
          formatter = SemanticLogger::Formatters::Json.new(time_key: :ts)
          parsed    = JSON.parse(formatter.call(log, appender))

          assert parsed.key?("ts")
          refute parsed.key?("timestamp")
        end

        it "honours a custom time_format" do
          formatter = SemanticLogger::Formatters::Json.new(time_format: "%Y-%m-%d")
          parsed    = JSON.parse(formatter.call(log, appender))

          assert_equal "2017-01-14", parsed["timestamp"]
        end

        it "serializes the standard fields" do
          log.message    = "Hello World"
          log.payload    = {first: 1, second: 2}
          log.tags       = %w[first second]
          log.named_tags = {user: "joe"}

          assert_equal "debug",          parsed["level"]
          assert_equal log.level_index,  parsed["level_index"]
          assert_equal "JsonTest",       parsed["name"]
          assert_equal "Hello World",    parsed["message"]
          assert_equal $$,               parsed["pid"]
          assert_equal({"first" => 1, "second" => 2}, parsed["payload"])
          assert_equal %w[first second], parsed["tags"]
          assert_equal({"user" => "joe"}, parsed["named_tags"])
        end

        it "serializes an exception" do
          begin
            raise "Oh no"
          rescue Exception => e
            log.exception = e
          end

          assert_equal "RuntimeError", parsed["exception"]["name"]
          assert_equal "Oh no",        parsed["exception"]["message"]
        end

        it "serializes an exception whose #message raises, with a cause of an anonymous class" do
          cause_class = Class.new(StandardError)
          begin
            begin
              raise cause_class, "disk full"
            rescue cause_class
              raise ExceptionFixtures::AbstractMessageError, "Order 7"
            end
          rescue ExceptionFixtures::AbstractMessageError => e
            log.exception = e
          end

          assert_equal "ExceptionFixtures::AbstractMessageError", parsed["exception"]["name"]
          assert_equal "Order 7", parsed["exception"]["message"]
          assert_equal cause_class.to_s, parsed["exception"]["cause"]["name"]
          assert_equal "disk full", parsed["exception"]["cause"]["message"]
        end

        # Issue #180: previously `.to_json` raised on non UTF-8 data (the exact class
        # varies by json gem version) and the log entry was dropped. Every field that
        # can carry caller-supplied strings must now serialize without raising.
        describe "non-UTF-8 data (issue #180)" do
          # A binary string holding a byte (0xE2) that is not valid UTF-8.
          let(:bad) { "Bad: \xE2".b }

          it "serializes host, application, and environment" do
            appender = Struct.new(:host, :application, :environment).new("host\xE2".b, "app\xE2".b, "env\xE2".b)
            parsed   = JSON.parse(formatter.call(log, appender))

            assert_equal "host", parsed["host"]
            assert_equal "app",  parsed["application"]
            assert_equal "env",  parsed["environment"]
          end

          it "serializes the name" do
            log.name = bad

            assert_equal "Bad: ", parsed["name"]
          end

          it "serializes the thread name" do
            log.thread_name = bad

            assert_equal "Bad: ", parsed["thread"]
          end

          it "serializes the message, stripped as any message is" do
            log.message = bad

            assert_equal "Bad:", parsed["message"]
          end

          it "serializes the metric name" do
            log.metric        = bad
            log.metric_amount = 3

            assert_equal "Bad: ", parsed["metric"]
            assert_equal 3, parsed["metric_amount"]
          end

          it "serializes the metric's dimensions" do
            log.metric     = "user/login"
            log.dimensions = {region: bad}

            assert_equal({"region" => "Bad: "}, parsed["dimensions"])
          end

          it "serializes tags" do
            log.tags = ["good", bad]

            assert_equal ["good", "Bad: "], parsed["tags"]
          end

          it "serializes named_tag keys and values" do
            log.named_tags = {"key\xE2".b => bad}

            assert_equal({"key" => "Bad: "}, parsed["named_tags"])
          end

          it "serializes a nested payload, including keys and arrays" do
            log.payload = {"outer\xE2".b => {inner: bad, list: [bad]}}

            assert_equal({"outer" => {"inner" => "Bad: ", "list" => ["Bad: "]}}, parsed["payload"])
          end

          it "serializes the exception message and backtrace" do
            exception = RuntimeError.new(bad)
            exception.set_backtrace(["good_file.rb:1", "bad_file\xE2.rb:2".b])
            log.exception = exception

            assert_equal "Bad: ", parsed["exception"]["message"]
            assert_equal ["good_file.rb:1", "bad_file.rb:2"], parsed["exception"]["stack_trace"]
          end

          it "serializes a nested cause exception message" do
            begin
              begin
                raise bad
              rescue StandardError
                raise "the effect"
              end
            rescue Exception => e
              log.exception = e
            end

            assert_equal "Bad: ", parsed["exception"]["cause"]["message"]
          end

          it "serializes everything at once without raising" do
            log.message    = bad
            log.tags       = [bad]
            log.named_tags = {"key\xE2".b => bad}
            log.payload    = {"outer\xE2".b => {inner: bad}}

            assert JSON.parse(formatter.call(log, appender))
          end

          it "does not mangle valid multibyte UTF-8 in the same document" do
            log.message = "€ café"
            log.payload = {"naïve" => "Bad: \xE2".b}

            assert_equal "€ café", parsed["message"]
            assert_equal({"naïve" => "Bad: "}, parsed["payload"])
          end
        end

        # Binary data usually holds UTF-8, such as a response body or Base64-decoded text. Its
        # characters are kept, and only its invalid bytes dropped.
        describe "binary data that holds UTF-8" do
          # Valid UTF-8 and one invalid byte (0xFF), so that no json gem version writes it as it is.
          let(:binary) { "Café \xFF☕".b }

          it "keeps the characters of the message" do
            log.message = "Café ☕".b

            assert_equal "Café ☕", parsed["message"]
          end

          it "keeps the characters of the message, dropping its invalid bytes" do
            log.message = binary

            assert_equal "Café ☕", parsed["message"]
          end

          it "keeps the characters of tags and named tags" do
            log.tags       = [binary]
            log.named_tags = {"clé".b => binary}

            assert_equal ["Café ☕"], parsed["tags"]
            assert_equal({"clé" => "Café ☕"}, parsed["named_tags"])
          end

          it "keeps the characters of payload keys and values" do
            log.payload = {"clé".b => {inner: binary, list: [binary]}}

            assert_equal({"clé" => {"inner" => "Café ☕", "list" => ["Café ☕"]}}, parsed["payload"])
          end

          # Such as the keys of a request's binary text turned into Symbols.
          it "keeps the characters of Symbol keys made from binary text" do
            log.named_tags = {binary.to_sym => "v"}
            log.payload    = {binary.to_sym => 1}

            assert_equal({"Café ☕" => "v"}, parsed["named_tags"])
            assert_equal({"Café ☕" => 1}, parsed["payload"])
          end

          it "keeps the characters of the exception message" do
            log.exception = RuntimeError.new(binary)

            assert_equal "Café ☕", parsed["exception"]["message"]
          end
        end

        describe "payload values that JSON cannot represent" do
          it "serializes a float that is not finite, instead of dropping the event" do
            log.message = "Transfer"
            log.payload = {amount: "1e400".to_f}

            assert_equal "Transfer", parsed["message"]
            assert_equal({"amount" => "Infinity"}, parsed["payload"])
          end

          it "serializes request params nested as deeply as JSON.parse accepts" do
            log.message = "Completed #create"
            log.payload = {params: JSON.parse("#{'{"a":' * 100}1#{'}' * 100}")}

            assert_equal "Completed #create", parsed["message"]
          end

          it "serializes a Struct as an object of its members, not its #inspect" do
            client = Object.new
            client.instance_variable_set(:@password, "secret")
            log.message = "Connected"
            log.payload = {connection: Struct.new(:host, :client).new("db1", client)}

            assert_equal({"host" => "db1", "client" => client.to_s}, parsed["payload"]["connection"])
            refute_includes formatter.call(log, appender), "secret"
          end
        end
      end
    end
  end
end
