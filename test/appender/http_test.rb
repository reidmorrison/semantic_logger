require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Http
module Appender
  class HttpTest < Minitest::Test
    describe SemanticLogger::Appender::Http do
      let(:http_success) { Net::HTTPSuccess.new("1.1", "200", "OK") }
      let(:log_message) { "AppenderHttpTest log message" }

      let(:appender) do
        Net::HTTP.stub_any_instance(:start, true) do
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
          Net::HTTP.stub_any_instance(:start, true) do
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
          inspected = Net::HTTP.stub_any_instance(:start, true) do
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
          appender = Net::HTTP.stub_any_instance(:start, true) do
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
          Net::HTTP.stub_any_instance(:start, true) do
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
          Net::HTTP.stub_any_instance(:start, true) do
            SemanticLogger::Appender::Http.new(url: url, header: {"Authorization" => "Bearer BEARER_TOKEN"})
          end
        end

        it "redacts the user, password, path, and query from the url" do
          assert_equal "https://logs.example.com:9200", appender.redacted_url
        end

        it "omits the default port from the redacted url" do
          appender = Net::HTTP.stub_any_instance(:start, true) do
            SemanticLogger::Appender::Http.new(url: "https://user:pass@logs.example.com/path")
          end

          assert_equal "https://logs.example.com", appender.redacted_url
        end

        it "redacts a token carried in the path" do
          appender = Net::HTTP.stub_any_instance(:start, true) do
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

        it "does not log credentials when the server rejects a request" do
          capture         = SemanticLogger::Test::CaptureLogEvents.new
          appender.logger = capture
          http_failure    = Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable")
          body            = "unavailable #{'x' * 1_000}"
          http_failure.define_singleton_method(:body) { body }

          appender.http.stub(:request, http_failure) do
            appender.info(log_message)
          end

          assert message = capture.events.find { |event| event.level == :error }&.message
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
        Net::HTTP.stub_any_instance(:start, true) do
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
        Net::HTTP.stub_any_instance(:start, true) do
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
        Net::HTTP.stub_any_instance(:start, true) do
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
        Net::HTTP.stub_any_instance(:start, true) do
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
