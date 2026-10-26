require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Opensearch
module Appender
  class OpenSearchTest < Minitest::Test
    describe SemanticLogger::Appender::Opensearch do
      let :client_class do
        ::OpenSearch::Client
      end

      it "does not show the password in #inspect" do
        appender = client_class.stub_any_instance(:bulk, true) do
          SemanticLogger::Appender::Opensearch.new(url: "https://admin:os-s3cr3t@os.example.com:9200")
        end

        refute_includes appender.inspect, "os-s3cr3t"
        assert_includes appender.inspect, %( url="https://os.example.com:9200")
      end

      it "does not include credentials in the error for a url that cannot be parsed" do
        error = assert_raises(URI::InvalidURIError) do
          SemanticLogger::Appender::Opensearch.new(url: "https://admin:os s3cr3t@os.example.com:9200")
        end

        refute_includes error.message, "s3cr3t"
        assert_nil error.cause
      end

      describe "providing a url" do
        let :appender do
          if ENV["OPENSEARCH"]
            SemanticLogger::Appender::Opensearch.new(url: "http://localhost:9200")
          else
            client_class.stub_any_instance(:bulk, true) do
              SemanticLogger::Appender::Opensearch.new(url: "http://localhost:9200")
            end
          end
        end

        let :log_message do
          "AppenderOpenSearchTest log message"
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

        it "does not include a document _type" do
          bulk_index = nil
          appender.stub(:bulk_write, ->(messages) { bulk_index = messages.first }) do
            appender.info log_message
          end

          refute bulk_index["index"].key?("_type"), bulk_index
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

      describe "logging to data-streams" do
        let :appender do
          client_class.stub_any_instance(:bulk, true) do
            SemanticLogger::Appender::Opensearch.new(
              url:         "http://localhost:9200",
              data_stream: true
            )
          end
        end

        let :log_message do
          "AppenderOpenSearchTest log message"
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

        it "logs to data-stream index without date" do
          request = stub_client { appender.log(log) }

          assert_equal "semantic_logger", request[:index]
          assert_equal({}, request[:body][0][:create])
          assert hash = request[:body][1]
          assert_equal log_message, hash[:message]
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
