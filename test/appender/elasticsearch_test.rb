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

      it "warns that the type: parameter is deprecated" do
        client_class.stub_any_instance(:bulk, true) do
          assert_deprecated(/SemanticLogger: .*`type:`.*deprecated/m) do
            SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200", type: "log")
          end
        end
      end

      it "does not warn when type: is omitted" do
        client_class.stub_any_instance(:bulk, true) do
          refute_deprecated do
            SemanticLogger::Appender::Elasticsearch.new(url: "http://localhost:9200")
          end
        end
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

        let :rejected do
          {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-rejected", "status" => 400,
                       "error" => {"type"   => "mapper_parsing_exception",
                                   "reason" => "failed to parse field [payload.amount] of type [long]"}}}
        end

        before do
          appender.logger = internal_logger
        end

        after do
          appender.close
        end

        it "reports only the entries that were not indexed" do
          write(created, rejected, updated)

          assert_equal 1, internal_logger.events.size
          event = internal_logger.events.first

          assert_equal :error, event.level
          assert_equal "1 of 3 log entries were not indexed, and are discarded: 400 mapper_parsing_exception " \
                       "in semantic_logger-2026.11.16: failed to parse field [payload.amount] of type [long]",
                       event.message
        end

        it "reports an entry with a status of 300 or above, even without an error" do
          unavailable = {"index" => {"_index" => "semantic_logger-2026.11.16", "_id" => "id-503", "status" => 503}}
          write(created, unavailable, created)

          assert_equal ["1 of 3 log entries were not indexed, and are discarded: 503 in semantic_logger-2026.11.16"],
                       internal_logger.events.map(&:message)
        end

        it "lists each failure once, with the number of entries that it failed" do
          blocked = {"index" => {"_index" => "semantic_logger-2026.11.16", "status" => 429,
                                 "error" => {"type"   => "cluster_block_exception",
                                             "reason" => "index [semantic_logger-2026.11.16] blocked by: " \
                                                         "[TOO_MANY_REQUESTS/12/disk usage exceeded]"}}}
          write(*Array.new(300, blocked))

          assert_equal ["300 of 300 log entries were not indexed, and are discarded: 429 cluster_block_exception " \
                        "in semantic_logger-2026.11.16: index [semantic_logger-2026.11.16] blocked by: " \
                        "[TOO_MANY_REQUESTS/12/disk usage exceeded] (300 entries)"],
                       internal_logger.events.map(&:message)
        end

        it "lists at most 10 different failures" do
          failures = Array.new(12) do |i|
            {"index" => {"_index" => "semantic_logger-2026.11.16", "status" => 400,
                         "error" => {"type" => "mapper_parsing_exception", "reason" => "field [f#{i}]"}}}
          end
          write(*failures)

          message = internal_logger.events.first.message

          assert_includes message, "12 of 12 log entries were not indexed"
          assert_includes message, "field [f9]"
          refute_includes message, "field [f10]"
          assert message.end_with?("; and 2 other failures"), message
        end

        it "reports nothing when every entry was indexed" do
          write(created, updated, created, errors: false)

          assert_empty internal_logger.events
        end

        # Sends a batch of one entry for each item, to a server that responds with these items.
        def write(*items, errors: true)
          response = {"took" => 3, "errors" => errors, "items" => items}
          appender.client.stub(:bulk, response) { appender.batch(Array.new(items.size, log)) }
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
            appender.stub(:bulk_write, ->(messages) { bulk_index = messages.first }) do
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
                        "in #{backing_index}: [1:15] failed to parse field [payload.amount]"],
                       internal.events.map(&:message)
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
            appender.stub(:bulk_write, ->(messages) { bulk_index = messages.first }) do
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
