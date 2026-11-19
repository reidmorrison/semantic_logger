require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Elasticsearch
module Appender
  class ElasticsearchHttpTest < Minitest::Test
    describe SemanticLogger::Appender::ElasticsearchHttp do
      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }
      let(:log_message) { "AppenderElasticsearchTest log message" }

      let(:appender) do
        stub_http_start do
          SemanticLogger::Appender::ElasticsearchHttp.new(
            url: "http://localhost:9200"
          )
        end
      end

      it "refuses to be batched, and says to use the :elasticsearch appender" do
        assert_includes appender.batch_refusal, "Use appender: :elasticsearch to send the entries in batches"
      end

      it "does not refuse a subclass that replaces the #batch it inherits" do
        bulk = Class.new(SemanticLogger::Appender::ElasticsearchHttp) do
          def batch(logs) = logs
        end

        assert_nil stub_http_start { bulk.new(url: "http://localhost:9200") }.batch_refusal
      end

      it "logs to daily indexes" do
        index = nil
        appender.stub(:post, ->(_json, ind) { index = ind }) do
          appender.info log_message
        end

        assert_equal "/semantic_logger-#{Time.now.strftime('%Y.%m.%d')}/_doc", index
      end

      it "raises an error for an entry that Elasticsearch rejects, that the appender says the entry caused" do
        rejected = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
        rejected.define_singleton_method(:body) { '{"error":{"type":"mapper_parsing_exception"}}' }

        error = appender.http.stub(:request, rejected) do
          assert_raises(SemanticLogger::Appender::Http::ResponseError) { appender.info(log_message) }
        end

        assert_includes error.message, "mapper_parsing_exception"
        assert appender.message_error?(error)
      end

      it "reports a response other than 2xx when deleting an index, and returns false" do
        capture         = SemanticLogger::Test::CaptureLogEvents.new
        appender.logger = capture
        not_found       = Net::HTTPNotFound.new("1.1", "404", "Not Found")
        not_found.define_singleton_method(:body) { "no such index" }

        deleted = appender.http.stub(:request, not_found) { appender.delete_all(Date.new(2026, 9, 5)) }

        refute deleted
        assert_equal 1, capture.events.size
        assert_includes capture.events.first.message, "code: 404"
      end

      describe "query parameters" do
        let(:appender) do
          stub_http_start do
            SemanticLogger::Appender::ElasticsearchHttp.new(
              url: "http://localhost:9200?refresh=true"
            )
          end
        end

        def capture_request(&block)
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }, &block)
          request
        end

        it "sends the query of the url when logging" do
          request = capture_request { appender.info(log_message) }

          assert_equal "/semantic_logger-#{Time.now.strftime('%Y.%m.%d')}/_doc?refresh=true", request.path
        end

        # The query configures how the server ingests log data. Elasticsearch fails an
        # index delete with a 400 when it carries unrecognized parameters.
        it "does not send the query when deleting an index" do
          request = capture_request { appender.delete_all(Date.new(2026, 9, 5)) }

          assert_equal "/semantic_logger-2026.09.05", request.path
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
          message = JSON.parse(request.body)

          assert_equal log_message, message["message"]
          assert_equal level.to_s, message["level"]
          refute message["exception"]
        end

        it "sends #{level} exceptions" do
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
          hash = JSON.parse(request.body)

          assert_equal "Reading File", hash["message"], hash
          assert exception = hash["exception"]
          assert_equal "NameError", exception["name"]
          assert_match "undefined local variable or method", exception["message"]
          assert_equal level.to_s, hash["level"]
          assert_includes exception["stack_trace"].first, __FILE__, exception
        end

        it "sends #{level} custom attributes" do
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, log_message, key1: 1, key2: "a")
          end
          message = JSON.parse(request.body)

          assert_equal log_message, message["message"]
          assert_equal level.to_s, message["level"]
          refute message["stack_trace"]
          assert payload = message["payload"], message
          assert_equal 1, payload["key1"], message
          assert_equal "a", payload["key2"], message
        end
      end
    end
  end
end
