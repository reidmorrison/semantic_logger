require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Http
module Appender
  class HttpTest < Minitest::Test
    response_mock = Struct.new(:code, :body)

    describe SemanticLogger::Appender::Http do
      let(:appender) { SemanticLogger::Appender::Http.new(url: "http://mockhost:8088/path") }
      let(:amessage) { "AppenderHttpTest log message" }

      SemanticLogger::LEVELS.each do |level|
        it "send #{level}" do
          request = nil
          appender.http.stub(:request, ->(r) { request = r; response_mock.new("200", "ok") }) do
            appender.send(level, amessage)
          end
          hash = JSON.parse(request.body)
          assert_equal amessage, hash["message"]
          assert_equal level.to_s, hash["level"]
          refute hash["stack_trace"]
        end

        it "send #{level} exceptions" do
          exc     = nil
          begin
            Uh oh
          rescue Exception => e
            exc = e
          end
          request = nil
          appender.http.stub(:request, ->(r) { request = r; response_mock.new("200", "ok") }) do
            appender.send(level, "Reading File", exc)
          end
          hash = JSON.parse(request.body)
          assert "Reading File", hash["message"]
          assert "NameError", hash["exception"]["name"]
          assert "undefined local variable or method", hash["exception"]["message"]
          assert_equal level.to_s, hash["level"], "Should be error level (3)"
          assert hash["exception"]["stack_trace"].first.include?(__FILE__), hash["exception"]
        end

        it "send #{level} custom attributes" do
          request = nil
          appender.http.stub(:request, ->(r) { request = r; response_mock.new("200", "ok") }) do
            appender.send(level, amessage, key1: 1, key2: "a")
          end
          hash = JSON.parse(request.body)
          assert_equal amessage, hash["message"]
          assert_equal level.to_s, hash["level"]
          refute hash["stack_trace"]
          assert payload = hash["payload"], hash
          assert_equal 1, payload["key1"], payload
          assert_equal "a", payload["key2"], payload
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
        proxy    = "http://user:password@proxy.example.com:12345"
        appender = SemanticLogger::Appender::Http.new(url: "http://mockhost:8088/path", proxy_url: proxy)

        proxy_uri = URI.parse(proxy)
        assert(appender.http.proxy?)
        refute(appender.http.proxy_from_env?)
        assert_equal(proxy_uri.host, appender.http.proxy_address)
        assert_equal(proxy_uri.port, appender.http.proxy_port)
        assert_equal(proxy_uri.user, appender.http.proxy_user)
        assert_equal(proxy_uri.password, appender.http.proxy_pass)
      end

      it "uses the ENV proxy if specified" do
        old_env_proxy     = ENV["http_proxy"]
        ENV["http_proxy"] = "http://user:password@proxy.example.com:12345"
        appender          = SemanticLogger::Appender::Http.new(url: "http://mockhost:8088/path")

        proxy_uri = URI.parse(ENV["http_proxy"])
        assert(appender.http.proxy?)
        assert(appender.http.proxy_from_env?)
        assert_equal(proxy_uri.host, appender.http.proxy_address)
        assert_equal(proxy_uri.port, appender.http.proxy_port)
        assert_equal(proxy_uri.user, appender.http.proxy_user)
        assert_equal(proxy_uri.password, appender.http.proxy_pass)

        ENV["http_proxy"] = old_env_proxy if old_env_proxy
      end

      it "doesn't use the ENV proxy if explicity requested" do
        old_env_proxy     = ENV["http_proxy"]
        ENV["http_proxy"] = "http://user:password@proxy.example.com:12345"
        appender          = SemanticLogger::Appender::Http.new(url: "http://mockhost:8088/path", proxy_url: nil)

        refute(appender.http.proxy_from_env?)
        refute(appender.http.proxy_address)
        refute(appender.http.proxy_user)
        refute(appender.http.proxy_pass)

        ENV["http_proxy"] = old_env_proxy if old_env_proxy
      end
    end
  end
end
