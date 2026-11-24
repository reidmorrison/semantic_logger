require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Elasticsearch
module Appender
  class ElasticsearchTest < Minitest::Test
    describe SemanticLogger::Appender::Elasticsearch do
      let :client_class do
        if Gem::Version.new(::Elasticsearch::VERSION) < Gem::Version.new(8)
          Elasticsearch::Transport::Client
        else
          Elasticsearch::Client
        end
      end

      it "does not show the password in #inspect" do
        appender = client_class.stub_any_instance(:bulk, true) do
          SemanticLogger::Appender::Elasticsearch.new(url: "https://elastic:es-s3cr3t@es.example.com:9200")
        end

        refute_includes appender.inspect, "es-s3cr3t"
        assert_includes appender.inspect, %( url="https://es.example.com:9200" index="semantic_logger">)
      end

      it "does not include credentials in the error for a url that cannot be parsed" do
        error = assert_raises(URI::InvalidURIError) do
          SemanticLogger::Appender::Elasticsearch.new(url: "https://elastic:es s3cr3t@es.example.com:9200")
        end

        refute_includes error.message, "s3cr3t"
        assert_nil error.cause
      end

      it "accepts a comma separated list of urls, which the client gem parses" do
        appender = client_class.stub_any_instance(:bulk, true) do
          SemanticLogger::Appender::Elasticsearch.new(url: "http://es1.example.com:9200,http://es2.example.com:9200")
        end

        assert_instance_of client_class, appender.client
      end

      describe "metric-only entries" do
        let :metric_only do
          log        = SemanticLogger::Log.new("Test", :info)
          log.metric = "orders/placed"
          log
        end

        it "leaves them out by default" do
          appender = client_class.stub_any_instance(:bulk, true) do
            SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200")
          end

          refute appender.should_log?(metric_only)
        end

        it "indexes them with metrics: true" do
          appender = client_class.stub_any_instance(:bulk, true) do
            SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200", metrics: true)
          end

          assert appender.should_log?(metric_only)
        end
      end

      describe "a bulk response with errors" do
        let :appender do
          client_class.stub_any_instance(:bulk, true) do
            SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200")
          end
        end

        let :internal_logger do
          SemanticLogger::Test::CaptureLogEvents.new
        end

        let :log do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = "hello world"
          log
        end

        let :created do
          {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-created", "_version" => 1,
                       "result" => "created", "_seq_no" => 0, "_primary_term" => 1, "status" => 201}}
        end

        let :updated do
          {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-updated", "_version" => 2,
                       "result" => "updated", "_seq_no" => 1, "_primary_term" => 1, "status" => 200}}
        end

        before do
          appender.logger = internal_logger
        end

        after do
          appender.close
        end

        it "reports only the entries that were not indexed" do
          write(created, mapping_error(1), updated)

          assert_equal 1, internal_logger.events.size
          event = internal_logger.events.first

          assert_equal :error, event.level
          assert_nil event.exception
          assert_nil event.payload
          assert_equal "1 of 3 log entries were not indexed, and are discarded: 400 mapper_parsing_exception " \
                       "in semantic_logger-2026.11.16: \"failed to parse field [payload.amount] of type [long] " \
                       "in document with id 'id-1'. Preview of field's value: 'abc1'\", caused by " \
                       'illegal_argument_exception: "For input string: \"abc1\""',
                       event.message
        end

        it "reports an entry with a status of 300 or above, even without an error" do
          unavailable = {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-503", "status" => 503}}
          write(created, unavailable, created)

          assert_equal ["1 of 3 log entries were not indexed, and are discarded: 503 in semantic_logger-2026.11.16"],
                       internal_logger.events.map(&:message)
        end

        it "groups the failures by status, error type, index, and innermost cause, with the reason of the first" do
          write(*Array.new(300) { |i| mapping_error(i) }, *Array.new(50) { |i| date_error(i) },
                *Array.new(100) { |i| rejection(i) })

          assert_equal ["450 of 450 log entries were not indexed, and are discarded: 400 mapper_parsing_exception " \
                        "in semantic_logger-2026.11.16 (300 entries), e.g.: \"failed to parse field [payload.amount] " \
                        "of type [long] in document with id 'id-0'. Preview of field's value: 'abc0'\", caused by " \
                        'illegal_argument_exception: "For input string: \"abc0\""; ' \
                        "400 mapper_parsing_exception in semantic_logger-2026.11.16 (50 entries), e.g.: \"failed to " \
                        "parse field [payload.at] of type [date] in document with id 'id-0'. Preview of field's " \
                        "value: 'yesterday'\", caused by illegal_argument_exception: \"failed to parse date field " \
                        "[yesterday] with format [strict_date_optional_time||epoch_millis]\", caused by " \
                        "date_time_parse_exception: \"Failed to parse with all enclosed parsers\"; " \
                        "429 es_rejected_execution_exception in semantic_logger-2026.11.16 (100 entries), e.g.: " \
                        "\"rejected execution of coordinating operation [coordinating_and_primary_bytes=104857000, " \
                        "replica_bytes=0, all_bytes=104857000, coordinating_operation_bytes=1048576, " \
                        "max_coordinating_and_primary_bytes=105906176]\""],
                       internal_logger.events.map(&:message)
        end

        it "writes each error that caused it, with the first line of each reason" do
          duplicate = failed_item(type: "mapper_parsing_exception", reason: "failed to parse",
                                  caused_by: {"type"   => "json_parse_exception",
                                              "reason" => "Duplicate field 'name'\n at [Source: (byte[])" \
                                                          "\"{\"name\":\"a\",\"name\":\"b\"}\"; line: 1, column: 22]"})
          write(duplicate)

          assert_equal ["1 of 1 log entries were not indexed, and are discarded: 400 mapper_parsing_exception " \
                        "in semantic_logger-2026.11.16: \"failed to parse\", caused by json_parse_exception: " \
                        "\"Duplicate field 'name'\""],
                       internal_logger.events.map(&:message)
        end

        it "writes a cause without a reason as its type alone" do
          write(failed_item(type: "mapper_parsing_exception", reason: "failed to parse",
                            caused_by: {"type" => "null_pointer_exception", "reason" => nil}))

          assert_equal ["1 of 1 log entries were not indexed, and are discarded: 400 mapper_parsing_exception " \
                        "in semantic_logger-2026.11.16: \"failed to parse\", caused by null_pointer_exception"],
                       internal_logger.events.map(&:message)
        end

        it "writes an error that is a String, as from Elasticsearch 1.x, as its reason" do
          legacy = {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-1", "status" => 400,
                                "error"  => "MapperParsingException[failed to parse [amount]]; nested: " \
                                            'NumberFormatException[For input string: "abc"]; '}}
          write(created, legacy, created)

          assert_equal ["1 of 3 log entries were not indexed, and are discarded: 400 in semantic_logger-2026.11.16: " \
                        '"MapperParsingException[failed to parse [amount]]; nested: NumberFormatException[For ' \
                        'input string: \"abc\"]; "'],
                       internal_logger.events.map(&:message)
        end

        it "cuts each reason to 500 characters, since it can repeat a whole value" do
          value = "9" * 100_000
          write(failed_item(type:      "mapper_parsing_exception",
                            reason:    "failed to parse field [payload.amount] of type [long] in document with id " \
                                       "'id-1'. Preview of field's value: '#{value}'",
                            caused_by: {"type"   => "illegal_argument_exception",
                                        "reason" => "Value [#{value}] is out of range for a long"}))

          message = internal_logger.events.first.message

          assert_operator message.size, :<, 1_200
          assert message.end_with?(%(caused by illegal_argument_exception: "Value [#{'9' * 493}"...)), message
        end

        it "escapes the control characters of a reason, so that a value cannot forge a line of the log" do
          forged = failed_item(type:   "mapper_parsing_exception",
                               reason: "failed to parse field [payload.count] of type [long] in document with id " \
                                       "'id-1'. Preview of field's value: " \
                                       "'abc\r\e[2K2026-11-16 E [1:main] Forged -- line\n'")
          write(forged)

          message = internal_logger.events.first.message

          refute_match(/[\r\n\e]/, message)
          assert message.end_with?(%q(Preview of field's value: 'abc\r\e[2K2026-11-16 E [1:main] Forged -- line")),
                 message
        end

        it "lists the first 10 failures, and counts the entries of the others" do
          write(*Array.new(10) { |i| failed_item(type: "exception_#{i}", reason: "reason #{i}") },
                *Array.new(100) { |i| rejection(i) })
          write(*Array.new(13) { |i| failed_item(type: "exception_#{i}", reason: "reason #{i}") })

          first, second = internal_logger.events.map(&:message)

          assert_includes first, "110 of 110 log entries were not indexed"
          refute_includes first, "es_rejected_execution_exception"
          last_listed = '400 exception_9 in semantic_logger-2026.11.16: "reason 9"'

          assert_equal "#{last_listed}; and 1 other failure (100 entries)", first[first.index(last_listed)..]
          assert_equal "#{last_listed}; and 3 other failures (3 entries)", second[second.index(last_listed)..]
        end

        it "reports nothing when every entry was indexed" do
          write(created, updated, created, errors: false)

          assert_empty internal_logger.events
        end

        describe "entries rejected with status 429" do
          let :logs do
            Array.new(4) do |i|
              log         = SemanticLogger::Log.new("User", :info)
              log.message = "entry #{i}"
              log
            end
          end

          it "sends again only those entries, until they are indexed" do
            requests, slept = serve([created, rejection(1), mapping_error(2), rejection(3)], [created, created]) do
              appender.batch(logs)
            end

            assert_equal [["entry 0", "entry 1", "entry 2", "entry 3"], ["entry 1", "entry 3"]], sent(requests)
            assert_equal [0.2], slept
            assert_equal 1, internal_logger.events.size
            assert_match(/\A1 of 4 log entries were not indexed, and are discarded: 400 mapper_parsing_exception /,
                         internal_logger.events.first.message)
          end

          it "sends them again 3 times, waiting longer each time, then reports those still rejected" do
            requests, slept = serve([created, rejection(1)], [rejection(1)], [rejection(1)], [rejection(1)]) do
              appender.batch(logs.first(2))
            end

            assert_equal [["entry 0", "entry 1"], ["entry 1"], ["entry 1"], ["entry 1"]], sent(requests)
            assert_equal [0.2, 0.4, 0.8], slept
            assert_equal 1, internal_logger.events.size
            assert_match(/\A1 of 2 log entries were not indexed, and are discarded: 429 es_rejected_execution/,
                         internal_logger.events.first.message)
          end

          it "reports an entry sent again that then fails for another reason" do
            requests, slept = serve([rejection(0), created], [mapping_error(0)]) { appender.batch(logs.first(2)) }

            assert_equal 2, requests.size
            assert_equal [0.2], slept
            assert_match(/\A1 of 2 log entries were not indexed, and are discarded: 400 mapper_parsing_exception /,
                         internal_logger.events.first.message)
          end

          it "sends again an entry logged on its own" do
            requests, slept = serve([rejection(0)], [created]) { appender.log(logs.first) }

            assert_equal [["entry 0"], ["entry 0"]], sent(requests)
            assert_equal [0.2], slept
            assert_empty internal_logger.events
          end

          it "reports the failures, with the error, when sending them again raises" do
            calls = 0
            bulk  = lambda do |_request|
              calls += 1
              raise IOError, "read timeout" if calls > 1

              {"took" => 1, "errors" => true, "items" => [created, rejection(1), mapping_error(2)]}
            end
            appender.stub(:sleep, nil) do
              appender.client.stub(:bulk, bulk) { appender.batch(logs.first(3)) }
            end

            assert_equal 2, calls
            assert_equal 1, internal_logger.events.size
            event = internal_logger.events.first

            assert_match(/\A2 of 3 log entries were not indexed, and are discarded: /, event.message)
            assert_includes event.message, "429 es_rejected_execution_exception"
            assert_includes event.message, "400 mapper_parsing_exception"
            assert_kind_of IOError, event.exception
          end

          it "does not wait when no entry was rejected with status 429" do
            requests, slept = serve([created, mapping_error(1)]) { appender.batch(logs.first(2)) }

            assert_equal 1, requests.size
            assert_empty slept
            assert_equal 1, internal_logger.events.size
          end

          # Answers each bulk request with the next of `responses`, the items of its entries, and records
          # the requests, and each wait instead of sleeping.
          def serve(*responses, &block)
            requests = []
            slept    = []
            bulk     = lambda do |request|
              requests << request
              items  = responses.shift
              errors = items.any? { |item| item.values.first["status"] >= 300 }
              {"took" => 1, "errors" => errors, "items" => items}
            end
            appender.stub(:sleep, ->(seconds) { slept << seconds }) do
              appender.client.stub(:bulk, bulk, &block)
            end
            [requests, slept]
          end

          # The messages of the entries of each bulk request.
          def sent(requests)
            requests.map do |request|
              request[:body].each_slice(2).map { |_action, document| JSON.parse(document)["message"] }
            end
          end
        end

        # Sends a batch of one entry for each item, to a server that responds with these items, and that
        # rejects again those it rejected with status 429 each time they are sent again, without waiting.
        def write(*items, errors: true)
          responses = [{"took" => 3, "errors" => errors, "items" => items}]
          rejected  = items.select { |item| item.values.first["status"] == 429 }
          bulk      = ->(_request) { responses.shift || {"took" => 1, "errors" => true, "items" => rejected} }
          appender.stub(:sleep, nil) do
            appender.client.stub(:bulk, bulk) { appender.batch(Array.new(items.size, log)) }
          end
        end

        # The item of an entry that failed with this error.
        def failed_item(type:, reason:, caused_by: nil)
          error              = {"type" => type, "reason" => reason}
          error["caused_by"] = caused_by if caused_by
          {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-#{type}", "status" => 400,
                       "error" => error}}
        end

        # The item of an entry whose number Elasticsearch 7 could not map: its reason names the
        # document's id, and the start of the value.
        def mapping_error(number)
          failed_item(type:      "mapper_parsing_exception",
                      reason:    "failed to parse field [payload.amount] of type [long] in document with id " \
                                 "'id-#{number}'. Preview of field's value: 'abc#{number}'",
                      caused_by: {"type"   => "illegal_argument_exception",
                                  "reason" => %(For input string: "abc#{number}")})
        end

        # The item of an entry whose date Elasticsearch 7 could not map: the error that caused it names
        # the expected format, and the innermost error does not.
        def date_error(number)
          failed_item(type:      "mapper_parsing_exception",
                      reason:    "failed to parse field [payload.at] of type [date] in document with id " \
                                 "'id-#{number}'. Preview of field's value: 'yesterday'",
                      caused_by: {"type"      => "illegal_argument_exception",
                                  "reason"    => "failed to parse date field [yesterday] with format " \
                                                 "[strict_date_optional_time||epoch_millis]",
                                  "caused_by" => {"type"   => "date_time_parse_exception",
                                                  "reason" => "Failed to parse with all enclosed parsers"}})
        end

        # The item of an entry that a node rejected, while it was indexing too much already.
        def rejection(number)
          bytes = 104_857_000 + number
          {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-rejected-#{number}", "status" => 429,
                       "error" => {"type"   => "es_rejected_execution_exception",
                                   "reason" => "rejected execution of coordinating operation " \
                                               "[coordinating_and_primary_bytes=#{bytes}, replica_bytes=0, " \
                                               "all_bytes=#{bytes}, coordinating_operation_bytes=1048576, " \
                                               "max_coordinating_and_primary_bytes=105906176]"}}}
        end
      end

      describe "providing a url" do
        let :appender do
          if ENV["ELASTICSEARCH"]
            SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200")
          else
            client_class.stub_any_instance(:bulk, true) do
              SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200")
            end
          end
        end

        let :log_message do
          "AppenderElasticsearchTest log message"
        end

        let :log do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = log_message
          log
        end

        let :exception do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          exc
        end

        after do
          appender.close
        end

        it "uses :timestamp as time_key" do
          assert_equal :timestamp, appender.formatter.time_key
        end

        it "raises a FormatError, a message error, for a document that cannot be serialized" do
          broken = Object.new
          def broken.to_json(*) = raise(NoMethodError, "undefined method 'name' for nil")
          log.payload = {broken: broken}

          error = assert_raises(SemanticLogger::Subscriber::FormatError) { appender.log(log) }

          assert appender.message_error?(error)
        end

        describe "synchronous" do
          it "logs to daily indexes" do
            bulk_index = nil
            appender.stub(:bulk_write, ->(entries) { bulk_index, = entries.first }) do
              appender.info log_message
            end
            index = bulk_index["index"]["_index"]

            assert_equal "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}", index
          end

          it "logs message" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
          end

          it "logs level" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal "info", hash[:level]
          end

          it "logs exception" do
            log.exception = exception
            request       = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert exception = hash[:exception]
            assert_equal "NameError", exception[:name]
            assert_match "undefined local variable or method", exception[:message]
            assert_includes exception[:stack_trace].first, __FILE__, exception
          end

          it "repairs a payload that the client gem cannot serialize, instead of dropping or leaking it" do
            client      = Class.new { def initialize = (@password = "hunter2") }.new
            log.payload = {amount: Float::INFINITY, agent: (+"Mozilla \xFF").b, client: Struct.new(:api).new(client)}
            request     = stub_client { appender.log(log) }

            payload = request[:body][1][:payload]

            assert_equal "Infinity", payload[:amount]
            assert_equal "Mozilla ", payload[:agent]
            refute_includes payload.to_s, "hunter2"
          end

          it "logs payload" do
            h           = {key1: 1, key2: "a"}
            log.payload = h
            request     = stub_client { appender.log(log) }

            request[:index]

            assert hash = request[:body][1]
            refute hash[:stack_trace]
            assert_equal h, hash[:payload], hash
          end
        end

        describe "async batch" do
          it "sends every message of a batch in a single request" do
            assert_predicate appender, :batch_all_or_nothing?
          end

          it "logs message" do
            request = stub_client { appender.batch([log]) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
            assert_equal "info", hash[:level]
          end

          let :logs do
            Array.new(3) do |i|
              l         = log.dup
              l.message = "hello world#{i + 1}"
              l
            end
          end

          it "logs multiple messages" do
            request = stub_client { appender.batch(logs) }

            assert body = request[:body]
            assert_equal 6, body.size, body

            index = "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}"

            assert_equal index, body[0][:index][:_index]
            assert_equal "hello world1", body[1][:message]
            assert_equal index, body[2][:index][:_index]
            assert_equal "hello world2", body[3][:message]
            assert_equal index, body[4][:index][:_index]
            assert_equal "hello world3", body[5][:message]
          end
        end

        # The appender sends each line of a bulk request as JSON: returns the request with them parsed.
        def stub_client(&block)
          request = nil
          appender.client.stub(:bulk, lambda { |r|
            request = r
            {"status" => 201}
          }, &block)
          request.merge(body: request[:body].map { |line| JSON.parse(line, symbolize_names: true) })
        end
      end

      describe "logging to data-streams" do
        let :appender do
          if ENV["ELASTICSEARCH"]
            SemanticLogger::Appender::Elasticsearch.new(
              url:         "http://localhost:9200",
              data_stream: true
            )
          else
            client_class.stub_any_instance(:bulk, true) do
              SemanticLogger::Appender::Elasticsearch.new(
                url:         "http://localhost:9200",
                data_stream: true
              )
            end
          end
        end

        let :log_message do
          "AppenderElasticsearchTest log message"
        end

        let :log do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = log_message
          log
        end

        after do
          appender.close
        end

        it "uses @timestamp as time_key" do
          assert_equal "@timestamp", appender.formatter.time_key
        end

        it "reports only the entries that were not indexed" do
          internal        = SemanticLogger::Test::CaptureLogEvents.new
          appender.logger = internal
          backing_index   = ".ds-semantic_logger-2026.11.16-000001"
          created         = {"create" => {"_index" => backing_index, "_id" => "id-created", "status" => 201}}
          rejected        = {"create" => {"_index" => backing_index, "_id" => "id-rejected", "status" => 400,
                                          "error" => {"type"   => "document_parsing_exception",
                                                      "reason" => "[1:15] failed to parse field [payload.amount]"}}}
          response        = {"took" => 3, "errors" => true, "items" => [created, rejected]}
          appender.client.stub(:bulk, response) { appender.batch([log, log]) }

          assert_equal ["1 of 2 log entries were not indexed, and are discarded: 400 document_parsing_exception " \
                        "in #{backing_index}: \"[1:15] failed to parse field [payload.amount]\""],
                       internal.events.map(&:message)
        end

        it "sends again to the data stream only the entries rejected with status 429" do
          internal        = SemanticLogger::Test::CaptureLogEvents.new
          appender.logger = internal
          backing_index   = ".ds-semantic_logger-2026.11.16-000001"
          created         = {"create" => {"_index" => backing_index, "_id" => "id-created", "status" => 201}}
          rejected        = {"create" => {"_index" => backing_index, "status" => 429,
                                          "error" => {"type"   => "es_rejected_execution_exception",
                                                      "reason" => "rejected execution of coordinating operation"}}}
          responses       = [{"took" => 3, "errors" => true, "items" => [created, rejected]},
                             {"took" => 1, "errors" => false, "items" => [created]}]
          requests        = []
          second          = log.dup
          second.message  = "second"
          bulk            = lambda do |request|
            requests << request
            responses.shift
          end
          appender.stub(:sleep, nil) do
            appender.client.stub(:bulk, bulk) { appender.batch([log, second]) }
          end

          assert_equal 2, requests.size
          assert_equal "semantic_logger", requests.last[:index]
          action, document = requests.last[:body]

          assert_equal({"create" => {}}, JSON.parse(action))
          assert_equal "second", JSON.parse(document)["message"]
          assert_empty internal.events
        end

        describe "synchronous" do
          it "logs to data-stream index without date" do
            request = stub_client { appender.log(log) }

            assert_equal "semantic_logger", request[:index]
            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
          end
        end

        describe "async batch" do
          it "logs message" do
            request = stub_client { appender.batch([log]) }

            assert body = request[:body]

            assert_equal({}, body[0][:create])
            assert hash = body[1]
            assert_equal log_message, hash[:message]
            assert_equal "info", hash[:level]
          end

          let :logs do
            Array.new(3) do |i|
              l         = log.dup
              l.message = "hello world#{i + 1}"
              l
            end
          end

          it "logs multiple messages" do
            request = stub_client { appender.batch(logs) }

            assert_equal "semantic_logger", request[:index]
            assert body = request[:body]
            assert_equal 6, body.size, body

            assert_equal({}, body[0][:create])
            assert_equal "hello world1", body[1][:message]
            assert_equal({}, body[2][:create])
            assert_equal "hello world2", body[3][:message]
            assert_equal({}, body[4][:create])
            assert_equal "hello world3", body[5][:message]
          end
        end

        # The appender sends each line of a bulk request as JSON: returns the request with them parsed.
        def stub_client(&block)
          request = nil
          appender.client.stub(:bulk, lambda { |r|
            request = r
            {"status" => 201}
          }, &block)
          request.merge(body: request[:body].map { |line| JSON.parse(line, symbolize_names: true) })
        end
      end

      describe "elasticsearch parameters" do
        let :appender do
          client_class.stub_any_instance(:bulk, true) do
            SemanticLogger::Appender::Elasticsearch.new(
              hosts: [{host: "localhost", port: 9200}]
            )
          end
        end

        let :log_message do
          "AppenderElasticsearchTest log message"
        end

        let :log do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = log_message
          log
        end

        let :exception do
          exc = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          exc
        end

        after do
          appender.close
        end

        describe "synchronous" do
          it "logs to daily indexes" do
            bulk_index = nil
            appender.stub(:bulk_write, ->(entries) { bulk_index, = entries.first }) do
              appender.info log_message
            end
            index = bulk_index["index"]["_index"]

            assert_equal "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}", index
          end

          it "logs message" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
          end

          it "logs level" do
            request = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert_equal "info", hash[:level]
          end

          it "logs exception" do
            log.exception = exception
            request       = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            assert exception = hash[:exception]
            assert_equal "NameError", exception[:name]
            assert_match "undefined local variable or method", exception[:message]
            assert_includes exception[:stack_trace].first, __FILE__, exception
          end

          it "logs payload" do
            h           = {key1: 1, key2: "a"}
            log.payload = h
            request     = stub_client { appender.log(log) }

            assert hash = request[:body][1]
            refute hash[:stack_trace]
            assert_equal h, hash[:payload], hash
          end
        end

        describe "async batch" do
          it "logs message" do
            request = stub_client { appender.batch([log]) }

            assert hash = request[:body][1]
            assert_equal log_message, hash[:message]
            assert_equal "info", hash[:level]
          end

          let :logs do
            Array.new(3) do |i|
              l         = log.dup
              l.message = "hello world#{i + 1}"
              l
            end
          end

          it "logs multiple messages" do
            request = stub_client { appender.batch(logs) }

            assert body = request[:body]
            assert_equal 6, body.size, body

            index = "semantic_logger-#{Time.now.strftime('%Y.%m.%d')}"

            assert_equal index, body[0][:index][:_index]
            assert_equal "hello world1", body[1][:message]
            assert_equal index, body[2][:index][:_index]
            assert_equal "hello world2", body[3][:message]
            assert_equal index, body[4][:index][:_index]
            assert_equal "hello world3", body[5][:message]
          end
        end

        # The appender sends each line of a bulk request as JSON: returns the request with them parsed.
        def stub_client(&block)
          request = nil
          appender.client.stub(:bulk, lambda { |r|
            request = r
            {"status" => 201}
          }, &block)
          request.merge(body: request[:body].map { |line| JSON.parse(line, symbolize_names: true) })
        end
      end
    end
  end
end
