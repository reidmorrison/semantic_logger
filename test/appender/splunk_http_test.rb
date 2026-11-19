require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::SplunkHttp
module Appender
  class SplunkHttpTest < Minitest::Test
    describe SemanticLogger::Appender::SplunkHttp do
      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }
      let(:log_message) { "AppenderSplunkHttpTest log message" }

      let(:appender) do
        stub_http_start do
          SemanticLogger::Appender::SplunkHttp.new(
            url:   "http://localhost:8088/path",
            token: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
          )
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
          body    = decompress_data(request.body)
          message = JSON.parse(body)

          assert_equal log_message, message["event"]["message"]
          assert_equal level.to_s, message["event"]["level"]
          refute message["event"]["exception"]
        end

        it "sends #{level} exceptions" do
          exc     = nil
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
          body = decompress_data(request.body)
          hash = JSON.parse(body)

          assert "Reading File", hash["message"]
          assert exception = hash["event"]["exception"]
          assert "NameError", exception["name"]
          assert "undefined local variable or method", exception["message"]
          assert_equal level.to_s, hash["event"]["level"]
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
          body    = decompress_data(request.body)
          message = JSON.parse(body)

          assert event = message["event"], message.ai
          refute_includes message["event"], "host"
          assert_equal log_message, event["message"]
          assert_equal level.to_s, event["level"]
          refute event["stack_trace"]
          assert payload = event["payload"], event
          assert_equal(1, payload["key1"], message)
          assert_equal("a", payload["key2"], message)
        end
      end

      it "cannot be batched with its default formatter, which is the appender itself" do
        assert_same appender, appender.formatter
        assert_equal "it is its own formatter, which cannot format a batch. Add it with batch: false.",
                     appender.batch_refusal
      end

      describe "a 400 Bad Request from the HTTP Event Collector" do
        let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }

        # Batched with a formatter that can format a batch, unlike the appender itself.
        let(:batch_appender) do
          stub_http_start do
            SemanticLogger::Appender::SplunkHttp.new(
              url:       "http://localhost:8088/services/collector/event",
              token:     "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
              compress:  false,
              formatter: :json
            )
          end
        end

        let(:processor) do
          SemanticLogger::QueueProcessor.new(appender: batch_appender, batch: true, batch_seconds: 0.01)
        end

        def response(code, body)
          response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "Status #{code}")
          response.define_singleton_method(:body) { body }
          response
        end

        def collector_body(code, text)
          %({"text":"#{text}","code":#{code}})
        end

        def error_for(code, body)
          appender.http.stub(:request, response(code, body)) do
            assert_raises(SemanticLogger::Appender::Http::ResponseError) { appender.info(log_message) }
          end
        end

        def new_log(message)
          log         = SemanticLogger::Log.new("User", :info)
          log.message = message
          log
        end

        # Writes the messages as a batch, as the worker thread of an asynchronous appender does, on
        # this thread, answering every request with the response. Returns the messages of each
        # request.
        def process_batch(messages, response)
          batch_appender.logger = internal_logger
          requests = []
          handler  = lambda do |request|
            processor.queue << SemanticLogger::QueueProcessor::Request.new(:close) if requests.empty?
            requests << JSON.parse(request.body).map { |entry| entry["message"] }
            response
          end
          messages.each { |message| processor.queue << new_log(message) }
          processor.signal.set
          batch_appender.http.stub(:request, handler) { processor.send(:process) }
          requests
        end

        {
          7  => "Incorrect index",
          10 => "Data channel is missing",
          11 => "Invalid data channel",
          14 => "ACK is disabled",
          16 => "Query string authorization is not enabled",
          21 => "Invalid token",
          22 => "Token disabled"
        }.each_pair do |code, text|
          it "says that code #{code}, #{text}, fails any batch" do
            error = error_for(400, collector_body(code, text))

            assert appender.message_error?(error)
            assert appender.fails_any_batch?(error)
            assert_includes error.message, text
          end
        end

        {
          5  => "No data",
          6  => "Invalid data format",
          12 => "Event field is required",
          13 => "Event field cannot be blank",
          15 => "Error in handling indexed fields"
        }.each_pair do |code, text|
          it "says that code #{code}, #{text}, caused by the entries, does not fail any batch" do
            error = error_for(400, collector_body(code, text))

            assert appender.message_error?(error)
            refute appender.fails_any_batch?(error)
          end
        end

        ["<html>Bad Request</html>", "", "[7]", %({"code":"7"})].each do |body|
          it "says that a 400 without a collector code, #{body.inspect}, does not fail any batch" do
            refute appender.fails_any_batch?(error_for(400, body))
          end
        end

        it "says that a 503 holding a configuration code does not fail any batch, since it is not a message error" do
          refute appender.fails_any_batch?(error_for(503, collector_body(7, "Incorrect index")))
        end

        it "discards a batch with an incorrect index at once, in one request, and reports it once with the text" do
          requests = process_batch(%w[first second third fourth], response(400, collector_body(7, "Incorrect index")))

          assert_equal [%w[first second third fourth]], requests
          assert_equal 0, processor.processed_count
          assert_equal 4, processor.failed_count
          reports = internal_logger.events.select { |event| event.message.include?("Discarded") }

          assert_equal 1, reports.size
          assert_includes reports.first.message, "Discarded 4 log message(s)"
          assert_includes reports.first.exception.message, "Incorrect index"
        end

        it "splits a batch with invalid data to find the entries at fault" do
          requests = process_batch(%w[first second], response(400, collector_body(6, "Invalid data format")))

          assert_equal [%w[first second], %w[first], %w[second]], requests
          assert_equal 2, processor.failed_count
        end
      end

      def decompress_data(data)
        str = StringIO.new(data)
        gz  = Zlib::GzipReader.new(str)
        raw = gz.read
        gz.close
        raw
      end
    end
  end
end
