require_relative "../test_helper"
require_relative "../forked_child_helper"
require_relative "../tls_server"

# Unit Test for SemanticLogger::Appender::Http
module Appender
  class HttpTest < Minitest::Test
    describe SemanticLogger::Appender::Http do
      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }
      let(:log_message) { "AppenderHttpTest log message" }

      let(:appender) do
        stub_http_start do
          SemanticLogger::Appender::Http.new(url: "http://localhost:8088/path")
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
          hash = JSON.parse(request.body)

          assert_equal log_message, hash["message"]
          assert_equal level.to_s, hash["level"]
          refute hash["stack_trace"]
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
          hash = JSON.parse(request.body)

          assert "Reading File", hash["message"]
          assert "NameError", hash["exception"]["name"]
          assert "undefined local variable or method", hash["exception"]["message"]
          assert_equal level.to_s, hash["level"], "Should be error level (3)"
          assert_includes hash["exception"]["stack_trace"].first, __FILE__, hash["exception"]
        end

        it "send #{level} custom attributes" do
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.send(level, log_message, key1: 1, key2: "a")
          end
          hash = JSON.parse(request.body)

          assert_equal log_message, hash["message"]
          assert_equal level.to_s, hash["level"]
          refute hash["stack_trace"]
          assert payload = hash["payload"], hash
          assert_equal 1, payload["key1"], payload
          assert_equal "a", payload["key2"], payload
        end
      end

      describe "batch" do
        let(:log1) do
          log         = SemanticLogger::Log.new("User", :info)
          log.message = "message 1"
          log
        end

        let(:log2) do
          log         = SemanticLogger::Log.new("User", :warn)
          log.message = "message 2"
          log
        end

        it "is not batched by default" do
          refute_predicate appender, :batch_by_default?
        end

        it "can be batched only with a formatter that can format a batch, as its default one can" do
          assert_nil appender.batch_refusal

          [->(log, _logger) { log.message }, :default].each do |formatter|
            appender.formatter = formatter

            assert_equal appender.send(:format_batch_refusal), appender.batch_refusal
            refute_nil appender.batch_refusal
          end
        end

        it "can be batched with any formatter by a subclass that replaces #batch" do
          subclass = Class.new(SemanticLogger::Appender::Http) do
            def batch(logs)
              post(logs.map { |log| format_log(log) }.join("\n"))
            end
          end
          appender = stub_http_start { subclass.new(url: "http://localhost:8088/path", formatter: ->(log, _) { log.message }) }

          assert_nil appender.batch_refusal
        end

        it "is refused by a subclass whose #batch calls super, once it defines #batch_refusal, as the docs show" do
          subclass = Class.new(SemanticLogger::Appender::Http) do
            def batch(logs)
              super(logs.reject { |log| log.name == "HealthCheck" })
            end

            def batch_refusal
              format_batch_refusal
            end
          end
          appender = stub_http_start { subclass.new(url: "http://localhost:8088/path", formatter: ->(log, _) { log.message }) }

          assert_equal appender.send(:format_batch_refusal), appender.batch_refusal
          refute_nil appender.batch_refusal
        end

        it "can be refused for a subclass that defines its own #method, such as for the HTTP verb" do
          subclass = Class.new(SemanticLogger::Appender::Http) do
            attr_reader :method
          end
          appender = stub_http_start { subclass.new(url: "http://localhost:8088/path", formatter: ->(log, _) { log.message }) }

          assert_equal appender.send(:format_batch_refusal), appender.batch_refusal
        end

        it "is not refused for a subclass without #batch, which add_appender then says it cannot batch" do
          subclass = Class.new(SemanticLogger::Appender::Http) do
            undef_method :batch
          end
          appender = stub_http_start { subclass.new(url: "http://localhost:8088/path") }

          assert_nil appender.batch_refusal
          error = assert_raises(ArgumentError) { SemanticLogger::Appender.factory(appender: appender, batch: true) }
          assert_includes error.message, "does not support batching"
        end

        it "sends nothing from a batch that has a message it cannot format" do
          assert_predicate appender, :batch_all_or_nothing?

          appender.formatter.stub(:batch, ->(*) { raise JSON::GeneratorError, "cannot serialize" }) do
            appender.http.stub(:request, ->(_) { flunk "must not send a partial batch" }) do
              error = assert_raises(SemanticLogger::Subscriber::FormatError) { appender.batch([log1, log2]) }

              assert_kind_of JSON::GeneratorError, error.cause
              assert appender.message_error?(error)
            end
          end
        end

        it "posts multiple log messages as a single JSON array" do
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.batch([log1, log2])
          end
          array = JSON.parse(request.body)

          assert_kind_of Array, array
          assert_equal 2, array.size
          assert_equal "message 1", array[0]["message"]
          assert_equal "info", array[0]["level"]
          assert_equal "message 2", array[1]["message"]
          assert_equal "warn", array[1]["level"]
        end
      end

      describe "#inspect" do
        let(:credentials) { %w[url-password proxy-password header-token query-token] }

        let(:appender_with_credentials) do
          stub_http_start do
            SemanticLogger::Appender::Http.new(
              url:       "https://user:url-password@localhost:8088/path?token=query-token",
              proxy_url: "http://proxy-user:proxy-password@localhost:3128",
              header:    {"Authorization" => "Bearer header-token"}
            )
          end
        end

        it "omits credentials" do
          inspected = appender_with_credentials.inspect

          credentials.each { |credential| refute_includes inspected, credential }
        end

        it "shows only the redacted url" do
          assert_match(%r{ url="https://localhost:8088">\z}, appender_with_credentials.inspect)
        end

        it "includes the object address, like Kernel#inspect" do
          assert_match(/\A#<SemanticLogger::Appender::Http:0x\h+ url=/, appender_with_credentials.inspect)
        end

        it "omits instance variables a subclass adds" do
          subclass = Class.new(SemanticLogger::Appender::Http) do
            def initialize(api_key:, **)
              @api_key = api_key
              super(**)
            end
          end
          inspected = stub_http_start do
            subclass.new(api_key: "subclass-secret", url: "http://localhost:8088/path").inspect
          end

          refute_includes inspected, "subclass-secret"
        end

        it "omits credentials when wrapped in an async proxy" do
          async = SemanticLogger::Appender::Async.new(appender: appender_with_credentials)
          inspected = async.inspect
          async.close

          credentials.each { |credential| refute_includes inspected, credential }
        end
      end

      describe "ssl:" do
        # Returns [SemanticLogger::Appender::Http] an appender for an https url built with the given ssl: option,
        # which connects to nothing.
        def appender_with(ssl)
          stub_http_start { SemanticLogger::Appender::Http.new(url: "https://localhost:8088/path", ssl: ssl) }
        end

        it "uses TLS for an https url, and leaves the Hash given as it is" do
          ssl      = {ca_file: "ca.pem"}
          appender = appender_with(ssl)

          assert_predicate appender.http, :use_ssl?
          assert_equal OpenSSL::SSL::VERIFY_PEER, appender.http.verify_mode
          assert_equal "ca.pem", appender.http.ca_file
          assert_equal({ca_file: "ca.pem"}, ssl)
        end

        it "accepts a frozen Hash" do
          appender = appender_with({verify_mode: OpenSSL::SSL::VERIFY_NONE}.freeze)

          assert_predicate appender.http, :use_ssl?
          assert_equal OpenSSL::SSL::VERIFY_NONE, appender.http.verify_mode
        end

        it "does not use TLS for an http url given a Hash that another appender uses for an https url" do
          ssl = {ca_file: "ca.pem"}
          appender_with(ssl)
          appender = stub_http_start { SemanticLogger::Appender::Http.new(url: "http://localhost:8088/path", ssl: ssl) }

          refute_predicate appender.http, :use_ssl?
        end
      end

      describe "query parameters" do
        it "has no query when the url carries none" do
          assert_nil appender.query
        end

        it "leaves the request uri alone when the url carries no query" do
          request = capture_request(appender) { appender.info(log_message) }

          assert_equal "/path", request.path
        end

        it "sends the query of the url with every request" do
          appender = build_appender("http://localhost:8088/path?_msg_field=message&_time_field=timestamp")

          assert_equal "_msg_field=message&_time_field=timestamp", appender.query
          request = capture_request(appender) { appender.info(log_message) }

          assert_equal "/path?_msg_field=message&_time_field=timestamp", request.path
        end

        it "sends the query with a batch as well" do
          appender = build_appender("http://localhost:8088/path?source=my_app")
          logs = ["message 1", "message 2"].map do |message|
            SemanticLogger::Log.new("User", :info).tap { |log| log.message = message }
          end
          request = capture_request(appender) { appender.batch(logs) }

          assert_equal "/path?source=my_app", request.path
        end

        # Appender::ElasticsearchHttp builds its request uri from the path, so the query
        # has to be applied after it, not merged into the path.
        it "keeps the query at the end of a request uri built by a subclass" do
          appender = stub_http_start do
            SemanticLogger::Appender::ElasticsearchHttp.new(
              url: "http://localhost:8088/insert/elasticsearch?source=my_app", index: "rs"
            )
          end
          log         = SemanticLogger::Log.new("User", :info)
          log.message = "message 1"
          log.time    = Time.new(2026, 9, 3)
          request     = capture_request(appender) { appender.log(log) }

          assert_equal "/insert/elasticsearch/rs-2026.09.03/_doc?source=my_app", request.path
        end

        it "joins a request uri that already carries a query" do
          appender = build_appender("http://localhost:8088/path?source=my_app")
          request = capture_request(appender) { appender.send(:post, "body", "/path?pretty=true") }

          assert_equal "/path?pretty=true&source=my_app", request.path
        end

        # The query configures how the server ingests log data, so it is not applied to a
        # maintenance request. See Appender::ElasticsearchHttp#delete_all.
        it "does not send the query with a delete" do
          appender = build_appender("http://localhost:8088/path?source=my_app")
          request = capture_request(appender) { appender.send(:delete, "/path/index") }

          assert_equal "/path/index", request.path
        end

        it "ignores an empty query" do
          appender = build_appender("http://localhost:8088/path?")

          assert_nil appender.query
          request = capture_request(appender) { appender.info(log_message) }

          assert_equal "/path", request.path
        end

        def build_appender(url)
          stub_http_start do
            SemanticLogger::Appender::Http.new(url: url)
          end
        end

        def capture_request(appender, &block)
          request = nil
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }, &block)
          request
        end
      end

      describe "credentials" do
        let(:url) { "https://elastic:S3cr3t@logs.example.com:9200/path?dd-api-key=0123456789abcdef" }
        let(:appender) do
          stub_http_start do
            SemanticLogger::Appender::Http.new(url: url, header: {"Authorization" => "Bearer BEARER_TOKEN"})
          end
        end

        it "redacts the user, password, path, and query from the url" do
          assert_equal "https://logs.example.com:9200", appender.redacted_url
        end

        it "omits the default port from the redacted url" do
          appender = stub_http_start do
            SemanticLogger::Appender::Http.new(url: "https://user:pass@logs.example.com/path")
          end

          assert_equal "https://logs.example.com", appender.redacted_url
        end

        it "redacts a token carried in the path" do
          appender = stub_http_start do
            SemanticLogger::Appender::Http.new(url: "https://collectors.example.com/receiver/v1/http/SECRETCODE")
          end

          assert_equal "https://collectors.example.com", appender.redacted_url
          refute_includes appender.inspect, "SECRETCODE"
        end

        it "does not include credentials in the error for a url without a host" do
          error = assert_raises(ArgumentError) do
            SemanticLogger::Appender::Http.new(url: "https//elastic:S3cr3t@logs.example.com/path")
          end

          assert_includes error.message, "Invalid format for :url"
          refute_includes error.message, "S3cr3t"
        end

        it "does not include credentials in the error for a url that cannot be parsed" do
          error = assert_raises(URI::InvalidURIError) do
            SemanticLogger::Appender::Http.new(url: "https://elastic:S3cr 3t@logs.example.com/path")
          end

          assert_includes error.message, "Invalid :url"
          refute_includes error.message, "S3cr"
          assert_nil error.cause
        end

        it "does not include credentials in the error for a proxy_url that cannot be parsed" do
          proxy_url = "http://proxyuser:pr0xy pw@proxy:3128"
          error     = assert_raises(URI::InvalidURIError) do
            SemanticLogger::Appender::Http.new(url: "http://localhost:8088", proxy_url: proxy_url)
          end

          assert_includes error.message, "Invalid :proxy_url"
          refute_includes error.message, "pr0xy"
          assert_nil error.cause
        end

        it "does not include credentials in the error when the server rejects a request" do
          http_failure = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
          body         = "unavailable #{'x' * 1_000}"
          http_failure.define_singleton_method(:body) { body }

          error = appender.http.stub(:request, http_failure) do
            assert_raises(SemanticLogger::Appender::Http::ResponseError) { appender.info(log_message) }
          end

          message = error.message

          assert_includes message, "https://logs.example.com:9200 "
          assert_includes message, "code: 503"
          refute_includes message, "S3cr3t"
          refute_includes message, "0123456789abcdef"
          refute_includes message, "/path"
          assert_operator message.size, :<, 700, "response body should be truncated"
        end

        it "does not reveal credentials or headers via inspect" do
          refute_includes appender.inspect, "S3cr3t"
          refute_includes appender.inspect, "BEARER_TOKEN"
          refute_includes appender.inspect, "0123456789abcdef"
        end
      end

      it "closes its connection, and does nothing when it is not open" do
        assert_predicate appender.http, :started?

        appender.close

        refute_predicate appender.http, :started?
        assert_nil appender.close
      end

      it "starts its connection again for the next request once closed, and keeps it for those that follow" do
        appender.close
        starts = 0
        Net::HTTP.stub_any_instance(:start, lambda {
          starts += 1
          @started = true
        }) do
          appender.http.stub(:request, http_success) do
            appender.info("one")
            appender.info("two")
          end
        end

        assert_equal 1, starts
        assert_predicate appender.http, :started?
      end

      describe "over https, after a fork" do
        include ForkedChildHelper

        let(:server) { TlsServer.new(http: true) }
        let(:https_appender) do
          appender = SemanticLogger::Appender::Http.new(
            url:       "https://127.0.0.1:#{server.port}/",
            ssl:       {verify_mode: OpenSSL::SSL::VERIFY_NONE},
            formatter: ->(log, _logger) { log.message }
          )
          # Keeps Net::HTTP from starting a new connection when the test takes longer than its default of 2 seconds.
          appender.http.keep_alive_timeout = 60
          appender
        end

        after do
          https_appender.close
          server.close
        end

        def log_with(message)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log
        end

        it "leaves the connection it inherited to the parent process, and connects again in the child" do
          https_appender.log(log_with("before"))
          in_forked_child do
            https_appender.reopen
            https_appender.log(log_with("child"))
            ""
          end
          https_appender.log(log_with("after"))

          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end

        it "starts a connection of its own for the next request in the child when a reopen there cannot" do
          https_appender.log(log_with("before"))
          output = in_forked_child do
            error = Net::HTTP.stub_any_instance(:start, -> { raise Errno::ECONNREFUSED }) do
              https_appender.reopen
            rescue Errno::ECONNREFUSED => e
              e
            end
            https_appender.log(log_with("child"))
            error.class.name
          end
          https_appender.log(log_with("after"))

          assert_equal "Errno::ECONNREFUSED", output
          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end

        it "leaves the connection it inherited to the parent when it is closed in a child that has not reopened" do
          https_appender.log(log_with("before"))
          in_forked_child do
            https_appender.close
            https_appender.log(log_with("child"))
            ""
          end
          https_appender.log(log_with("after"))

          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end
      end

      describe "a response other than 2xx" do
        let(:internal_logger) { SemanticLogger::Test::CaptureLogEvents.new }

        def response(code)
          response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "Status #{code}")
          response.define_singleton_method(:body) { "Status #{code}" }
          response
        end

        def new_log(message)
          log         = SemanticLogger::Log.new("User", :info)
          log.message = message
          log
        end

        def error_for(code)
          appender.http.stub(:request, response(code)) do
            assert_raises(SemanticLogger::Appender::Http::ResponseError) { appender.info(log_message) }
          end
        end

        # Writes the messages as the worker thread of an asynchronous appender does, on this thread.
        # Answers each request with the status of the first entry in it found in `statuses`, or
        # 200, and closes the processor once the first request is answered, so that it stops after
        # the messages are written. A status given as an Array answers the requests for that entry
        # in turn, then 200, and an exception class in it is raised instead. Returns the messages of
        # the entries the server took, and each back-off, recorded instead of waiting.
        def process(processor, messages, statuses)
          delivered = []
          slept     = []
          requests  = 0
          handler   = lambda do |request|
            requests += 1
            processor.queue << SemanticLogger::QueueProcessor::Request.new(:close) if requests == 1
            body     = JSON.parse(request.body)
            entries  = (body.is_a?(Array) ? body : [body]).map { |entry| entry["message"] }
            code     = entries.filter_map { |message| status_for(statuses, message) }.first || 200
            raise code, "failed" if code.is_a?(Class)

            delivered.concat(entries) if code == 200
            response(code)
          end
          messages.each { |message| processor.queue << new_log(message) }
          processor.signal&.set
          backoff = processor.instance_variable_get(:@backoff)
          appender.http.stub(:request, handler) do
            backoff.stub(:wait, -> { slept << backoff.retry_count }) { processor.send(:process) }
          end
          [delivered, slept]
        end

        def status_for(statuses, message)
          status = statuses[message]
          status.is_a?(Array) ? status.shift : status
        end

        [400, 401, 403, 404, 413, 422].each do |code|
          it "raises an error for a #{code} that the appender says the entries caused" do
            error = error_for(code)

            assert_equal code, error.code
            assert_equal "Status #{code}", error.body
            assert_predicate error, :rejected?
            assert appender.message_error?(error)
          end
        end

        [400, 413, 422].each do |code|
          it "says that a #{code}, which rejects the request for the entries it holds, does not fail any batch" do
            error = error_for(code)

            assert_predicate error, :content_rejected?
            refute appender.fails_any_batch?(error)
          end
        end

        [401, 403, 404, 405, 409, 410, 415].each do |code|
          it "says that a #{code}, which rejects the request whatever it holds, fails any batch" do
            error = error_for(code)

            refute_predicate error, :content_rejected?
            assert appender.message_error?(error)
            assert appender.fails_any_batch?(error)
          end
        end

        it "says that a batch it could not format does not fail any batch" do
          refute appender.fails_any_batch?(SemanticLogger::Subscriber::FormatError.new("Could not format"))
        end

        [408, 429, 500, 503].each do |code|
          it "says that a #{code}, which is not a message error, does not fail any batch" do
            refute appender.fails_any_batch?(error_for(code))
          end
        end

        [500, 502, 503, 504, 408, 429, 301].each do |code|
          it "raises an error for a #{code} that the appender says the destination caused" do
            error = error_for(code)

            assert_equal code, error.code
            refute_predicate error, :rejected?
            refute appender.message_error?(error)
          end
        end

        describe "#wrote_nothing?" do
          [408, 429, 503].each do |code|
            it "is true for a #{code}, which asks to send the request again later" do
              error = error_for(code)

              assert_predicate error, :retry_later?
              assert appender.wrote_nothing?(error)
            end
          end

          # A 500 often comes again for the same request, and a proxy can answer a 502 or 504 once the
          # server behind it has stored the request.
          [500, 502, 504, 501, 301, 400].each do |code|
            it "is false for a #{code}, which is not worth sending again" do
              error = error_for(code)

              refute_predicate error, :retry_later?
              refute appender.wrote_nothing?(error)
            end
          end

          [SocketError, Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           Errno::EADDRNOTAVAIL].each do |error_class|
            it "is true for #{error_class}, raised before the request was sent" do
              assert appender.wrote_nothing?(error_class.new)
            end
          end

          [Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET, Errno::EPIPE, EOFError, IOError,
           OpenSSL::SSL::SSLError].each do |error_class|
            it "is false for #{error_class}, after which the server may have stored the entries" do
              refute appender.wrote_nothing?(error_class.new)
            end
          end

          # Ruby sets the cause of an error to the one being handled when it is raised, which says
          # nothing about the request.
          it "is true for an error connecting raised while handling another, such as a format error" do
            error = begin
              begin
                raise SemanticLogger::Subscriber::FormatError, "cannot format"
              rescue SemanticLogger::Subscriber::FormatError
                raise Errno::ECONNREFUSED
              end
            rescue Errno::ECONNREFUSED => e
              e
            end

            assert_kind_of SemanticLogger::Subscriber::FormatError, error.cause
            assert appender.wrote_nothing?(error)
          end

          # As Net::HTTP raises it on Ruby 4.0.
          it "is true for an open timeout raised while handling an IO::TimeoutError" do
            error = begin
              begin
                raise IO::TimeoutError, "Blocking operation timed out!"
              rescue IO::TimeoutError
                raise Net::OpenTimeout, "Failed to open TCP connection"
              end
            rescue Net::OpenTimeout => e
              e
            end

            assert appender.wrote_nothing?(error)
          end

          it "is true for the error Net::HTTP raises when the server refuses the connection" do
            server = TCPServer.new("127.0.0.1", 0)
            port   = server.addr[1]
            server.close
            error = assert_raises(Errno::ECONNREFUSED) do
              Net::HTTP.new("127.0.0.1", port).request(Net::HTTP::Post.new("/"))
            end

            assert appender.wrote_nothing?(error)
          end
        end

        describe "#not_sent?" do
          [SocketError, Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           Errno::EADDRNOTAVAIL].each do |error_class|
            it "is true for #{error_class}, raised before the request was sent" do
              assert appender.not_sent?(error_class.new)
            end
          end

          it "is false for a response, which the server sent" do
            refute appender.not_sent?(error_for(503))
          end

          [Net::ReadTimeout, Errno::ECONNRESET, EOFError].each do |error_class|
            it "is false for #{error_class}, raised once the request was sent" do
              refute appender.not_sent?(error_class.new)
            end
          end
        end

        it "raises the error of a request whose answer timed out, rather than one from connecting again" do
          appender.logger = internal_logger
          refused         = -> { raise Errno::ECONNREFUSED }
          error           = appender.stub(:reopen, refused) do
            appender.http.stub(:request, ->(_request) { raise Net::ReadTimeout }) do
              assert_raises(Net::ReadTimeout) { appender.info(log_message) }
            end
          end

          refute appender.wrote_nothing?(error)
          report = internal_logger.events.find { |event| event.message.include?("Could not connect again") }

          assert report, "the failure to connect again should be reported"
          assert_equal :warn, report.level
          assert_kind_of Errno::ECONNREFUSED, report.exception
        end

        # Connecting again straight away would fail the same way, so that a server that cannot be
        # reached would hold up each request for twice the open_timeout.
        it "does not connect again after a request it could not send" do
          reopened = false
          appender.stub(:reopen, -> { reopened = true }) do
            appender.http.stub(:request, ->(_request) { raise Net::OpenTimeout }) do
              assert_raises(Net::OpenTimeout) { appender.info(log_message) }
            end
          end

          refute reopened
        end

        it "is not a RuntimeError, so the connection is kept" do
          reopened = false
          appender.stub(:reopen, -> { reopened = true }) { error_for(503) }

          refute reopened
        end

        describe "with async: true" do
          before { appender.logger = internal_logger }

          let(:processor) { SemanticLogger::QueueProcessor.new(appender: appender) }

          it "discards an entry the server rejects, and carries on without backing off" do
            delivered, slept = process(processor, %w[first rejected last], {"rejected" => 400})

            assert_equal %w[first last], delivered
            assert_empty slept
            assert_equal 2, processor.processed_count
            assert_equal 1, processor.failed_count

            report = internal_logger.events.find { |event| event.message.include?("Discarded") }

            assert_kind_of SemanticLogger::Appender::Http::ResponseError, report.exception
            assert_includes report.exception.message, "code: 400"
          end

          it "sends an entry the server cannot take yet again, once it has backed off" do
            delivered, slept = process(processor, %w[unavailable last], {"unavailable" => [503, 503]})

            assert_equal %w[unavailable last], delivered
            assert_equal [1, 2], slept
            assert_equal 2, processor.processed_count
            assert_equal 0, processor.failed_count
          end

          it "sends an entry again when it could not connect" do
            delivered, slept = process(processor, %w[refused last], {"refused" => [Errno::ECONNREFUSED]})

            assert_equal %w[refused last], delivered
            assert_equal [1], slept
            assert_equal 0, processor.failed_count
          end

          it "discards an entry the server answers with a 503 every time, once sent again 3 times" do
            delivered, slept = process(processor, %w[unavailable last], {"unavailable" => [503] * 10})

            assert_equal %w[last], delivered
            assert_equal [1, 2, 3, 4], slept
            assert_equal 1, processor.processed_count
            assert_equal 1, processor.failed_count
          end

          it "sends an entry again for as long as it cannot connect, without counting it towards the 3 times" do
            refused          = [Errno::ECONNREFUSED] * 6
            delivered, slept = process(processor, %w[refused last], {"refused" => refused})

            assert_equal %w[refused last], delivered
            assert_equal [1, 2, 3, 4, 5, 6], slept
            assert_equal 0, processor.failed_count
          end

          it "counts only the server's answers towards the 3 times an entry is sent again" do
            statuses         = [503, Errno::ECONNREFUSED, 503, Net::OpenTimeout, 503, 503]
            delivered, slept = process(processor, %w[unavailable last], {"unavailable" => statuses})

            assert_equal %w[last], delivered
            assert_equal [1, 2, 3, 4, 5, 6], slept
            assert_equal 1, processor.failed_count
          end

          [500, 502, 504].each do |code|
            it "discards an entry the server answers with a #{code} at once, then backs off" do
              delivered, slept = process(processor, %w[failed last], {"failed" => [code]})

              assert_equal %w[last], delivered
              assert_equal [1], slept
              assert_equal 1, processor.processed_count
              assert_equal 1, processor.failed_count
            end
          end

          it "discards an entry whose connection was reset, after the server may have stored it, then backs off" do
            delivered, slept = process(processor, %w[reset last], {"reset" => [Errno::ECONNRESET]})

            assert_equal %w[last], delivered
            assert_equal [1], slept
            assert_equal 1, processor.processed_count
            assert_equal 1, processor.failed_count
          end
        end

        describe "with batch: true" do
          before { appender.logger = internal_logger }

          # Waits only briefly for the close, which comes after the batch.
          let(:processor) do
            SemanticLogger::QueueProcessor.new(appender: appender, batch: true, batch_seconds: 0.01)
          end

          # Returns the messages of each batch sent while the block runs.
          def recording_batches(&)
            batches   = []
            original  = appender.method(:batch)
            recording = lambda do |logs|
              batches << logs.map(&:message)
              original.call(logs)
            end
            appender.stub(:batch, recording, &)
            batches
          end

          [400, 413, 422].each do |code|
            it "discards only the entry the server rejects with a #{code}, by sending the rest of the batch again" do
              messages         = %w[first rejected third fourth]
              delivered, slept = process(processor, messages, {"rejected" => code})

              assert_equal %w[first third fourth], delivered
              assert_empty slept
              assert_equal 3, processor.processed_count
              assert_equal 1, processor.failed_count
            end
          end

          [401, 403, 404, 405].each do |code|
            it "discards a batch the server rejects whatever it holds, with a #{code}, at once, in one request" do
              delivered = slept = nil
              batches   = recording_batches do
                delivered, slept = process(processor, %w[first second third fourth], {"second" => code})
              end

              assert_equal [%w[first second third fourth]], batches
              assert_empty delivered
              assert_empty slept
              assert_equal 0, processor.processed_count
              assert_equal 4, processor.failed_count
              reports = internal_logger.events.select { |event| event.message.include?("Discarded") }

              assert_equal 1, reports.size
              assert_includes reports.first.message, "Discarded 4 log message(s)"
            end
          end

          it "sends a batch the server cannot take yet again, as it was, once it has backed off" do
            batches  = []
            original = appender.method(:batch)
            recording = lambda do |logs|
              batches << logs.map(&:message)
              original.call(logs)
            end
            appender.stub(:batch, recording) do
              delivered, slept = process(processor, %w[first second third], {"second" => [429]})

              assert_equal %w[first second third], delivered
              assert_equal [1], slept
            end

            assert_equal [%w[first second third]] * 2, batches
            assert_equal 3, processor.processed_count
            assert_equal 0, processor.failed_count
          end
        end

        it "reports one error for each entry it cannot write, without raising, when not asynchronous" do
          appenders = SemanticLogger::Appenders.new(internal_logger)
          appenders << appender
          appender.http.stub(:request, response(503)) do
            2.times { appenders.log(new_log("unavailable")) }
          end

          errors = internal_logger.events.select { |event| event.level == :error }

          assert_equal 2, errors.size
          assert_includes errors.first.message, "Failed to log to appender"
          assert_kind_of SemanticLogger::Appender::Http::ResponseError, errors.first.exception
          assert_includes errors.first.exception.message, "code: 503"
        end
      end

      it "supports http 204 success" do
        http_success = Net::HTTPSuccess.new("1.1", "204", "OK")
        request = nil
        appender.http.stub(:request, lambda { |r|
          request = r
          http_success
        }) do
          appender.info(log_message)
        end
        hash = JSON.parse(request.body)

        assert_equal log_message, hash["message"]
      end

      it "supports custom headers" do
        stub_http_start do
          request = nil
          header = {"Authorization" => "Bearer BEARER_TOKEN"}
          appender = SemanticLogger::Appender::Http.new(url: "http://localhost:8088/path", header: header)
          appender.http.stub(:request, lambda { |r|
            request = r
            http_success
          }) do
            appender.info(log_message)
          end

          assert_equal(header["Authorization"], request["Authorization"])
        end
      end

      # We need to use a valid address that doesn't resolve to a localhost
      # address in order to check the proxy.  Net::HTTP uses URI::Generic#find_proxy
      # to determine the proxy to use, which will return nil if the hostname resolves
      # to 127.* or ::1.
      #
      # Unfortunately this probably also means that this test will fail if it's
      # run on a machine that cannot resolve hostnames
      it "uses a proxy if specified" do
        proxy = "http://user:password@proxy.example.com:12345"
        stub_http_start do
          appender = SemanticLogger::Appender::Http.new(url: "http://ruby-lang.org:8088/path", proxy_url: proxy)

          proxy_uri = URI.parse(proxy)

          assert_predicate(appender.http, :proxy?)
          refute_predicate(appender.http, :proxy_from_env?)
          assert_equal(proxy_uri.host, appender.http.proxy_address)
          assert_equal(proxy_uri.port, appender.http.proxy_port)
          assert_equal(proxy_uri.user, appender.http.proxy_user)
          assert_equal(proxy_uri.password, appender.http.proxy_pass)
        end
      end

      it "uses the ENV proxy if specified" do
        old_env_proxy = ENV.fetch("http_proxy", nil)
        ENV["http_proxy"] = "http://user:password@proxy.example.com:12345"
        stub_http_start do
          appender = SemanticLogger::Appender::Http.new(url: "http://ruby-lang.org:8088/path")

          proxy_uri = URI.parse(ENV.fetch("http_proxy", nil))

          assert_predicate(appender.http, :proxy?)
          assert_predicate(appender.http, :proxy_from_env?)
          assert_equal(proxy_uri.host, appender.http.proxy_address)
          assert_equal(proxy_uri.port, appender.http.proxy_port)
          assert_equal(proxy_uri.user, appender.http.proxy_user)
          assert_equal(proxy_uri.password, appender.http.proxy_pass)
        end

        ENV["http_proxy"] = old_env_proxy if old_env_proxy
      end

      it "doesn't use the ENV proxy if explicity requested" do
        old_env_proxy = ENV.fetch("http_proxy", nil)
        ENV["http_proxy"] = "http://user:password@proxy.example.com:12345"
        stub_http_start do
          appender = SemanticLogger::Appender::Http.new(url: "http://ruby-lang.org:8088/path", proxy_url: nil)

          refute_predicate(appender.http, :proxy_from_env?)
          refute(appender.http.proxy_address)
          refute(appender.http.proxy_user)
          refute(appender.http.proxy_pass)
        end

        ENV["http_proxy"] = old_env_proxy if old_env_proxy
      end
    end
  end
end
