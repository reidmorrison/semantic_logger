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
