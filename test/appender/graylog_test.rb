require_relative "../test_helper"
require_relative "../forked_child_helper"
require_relative "../tls_server"

# Unit Test for SemanticLogger::Appender::Graylog
module Appender
  class GraylogTest < Minitest::Test
    describe SemanticLogger::Appender::Graylog do
      let(:appender) { SemanticLogger::Appender::Graylog.new(level: :info) }
      let(:amessage) { "AppenderGraylogTest log message" }

      it "repairs a payload that GELF cannot serialize, instead of dropping or leaking it" do
        client  = Class.new { def initialize = (@password = "hunter2") }.new
        payload = {amount: Float::NAN, agent: (+"Mozilla \xFF").b, client: Struct.new(:api).new(client)}
        hash    = nil
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.info("Webhook received", payload)
        end

        assert_equal "NaN", hash[:payload][:amount]
        assert_equal "Mozilla ", hash[:payload][:agent]
        refute_includes hash.to_json, "hunter2"
      end

      it "sends a placeholder short_message for a message that is empty once cleansed" do
        hash = nil
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.info("\e[1m\e[0m  ")
        end

        assert_equal "<no-exception-message>", hash[:short_message]
      end

      it "sends the exception message as short_message for an empty message, or the placeholder when blank" do
        sent = []
        appender.notifier.stub(:notify!, ->(h) { sent << h[:short_message] }) do
          appender.error("", RuntimeError.new("Disk full"))
          appender.error("", RuntimeError.new("  "))
        end

        assert_equal ["Disk full", "<no-exception-message>"], sent
      end

      it "sends the message an exception was raised with as short_message when its #message raises" do
        sent = []
        appender.notifier.stub(:notify!, ->(h) { sent << h[:short_message] }) do
          appender.error("", ExceptionFixtures::BrokenMessageError.new("Order 7"))
          appender.error("", ExceptionFixtures::AbstractMessageError.new("Order 8"))
        end

        assert_equal ["Order 7", "Order 8"], sent
      end

      it "sends an exception message with bytes that are not valid UTF-8 as short_message, without them" do
        hash = nil
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.error("", RuntimeError.new((+" Disk full \xFF ").force_encoding(Encoding::UTF_8)))
        end

        assert_equal "Disk full", hash[:short_message]
      end

      it "hands GELF the formatted Hash itself, without copying it, when JSON can write it" do
        hash = nil
        SemanticLogger::Utils.stub(:json_safe, ->(*) { flunk "must not copy a Hash that JSON can write" }) do
          appender.notifier.stub(:notify!, ->(h) { hash = h }) do
            appender.info("Hello", user: "jack")
          end
        end

        assert_equal "Hello", hash[:short_message]
      end

      describe "gelf_options:" do
        it "leaves the Hash given as it is, and sends with the protocol of the url and the application" do
          gelf_options = {_team: "billing"}
          appender     = SemanticLogger::Appender::Graylog.new(gelf_options: gelf_options, application: "Shop")

          assert_equal({_team: "billing"}, gelf_options)
          assert_equal GELF::Protocol::UDP, appender.notifier.default_options["protocol"]
          assert_equal "Shop", appender.notifier.default_options["facility"]
          assert_equal "billing", appender.notifier.default_options["_team"]
        end

        it "accepts a frozen Hash" do
          appender = SemanticLogger::Appender::Graylog.new(gelf_options: {facility: "payments"}.freeze)

          assert_equal "payments", appender.notifier.default_options["facility"]
        end

        it "sends over TCP for a tcp url given a Hash that another appender uses for a udp url" do
          gelf_options = {}
          SemanticLogger::Appender::Graylog.new(url: "udp://localhost:12201", gelf_options: gelf_options)
          appender = GELF::Transport::TCP.stub_any_instance(:addresses=, nil) do
            SemanticLogger::Appender::Graylog.new(url: "tcp://localhost:12201", gelf_options: gelf_options)
          end

          assert_equal GELF::Protocol::TCP, appender.notifier.default_options["protocol"]
        end
      end

      describe "over TCP with TLS, after a fork" do
        include ForkedChildHelper

        let(:server) { TlsServer.new(separator: "\0") }
        let(:tls_appender) do
          SemanticLogger::Appender::Graylog.new(
            url:          "tcp://127.0.0.1:#{server.port}",
            gelf_options: {tls: {"no_verify" => true}}
          )
        end

        after do
          server.close
        end

        def log_with(message)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log
        end

        # Returns [Array] the short_message of each GELF message that the given connection received, or :closed.
        def short_messages(connection, count)
          server.received(connection, count).map do |record|
            record == :closed ? record : JSON.parse(record)["short_message"]
          end
        end

        it "leaves the connection it inherited to the parent process, and connects again in the child" do
          tls_appender.log(log_with("before"))
          in_forked_child do
            tls_appender.reopen
            tls_appender.log(log_with("child"))
            ""
          end
          tls_appender.log(log_with("after"))

          assert_equal %w[before after], short_messages(1, 2)
          assert_equal ["child", :closed], short_messages(2, 2)
        end

        it "connects in the child when a reopen there cannot, rather than writing through the parent's connection" do
          tls_appender.log(log_with("before"))
          output = in_forked_child do
            error = GELF::Notifier.stub(:new, ->(*) { raise Errno::ECONNREFUSED }) do
              tls_appender.reopen
            rescue Errno::ECONNREFUSED => e
              e
            end
            tls_appender.log(log_with("child"))
            error.class.name
          end
          tls_appender.log(log_with("after"))

          assert_equal "Errno::ECONNREFUSED", output
          assert_equal %w[before after], short_messages(1, 2)
          assert_equal ["child", :closed], short_messages(2, 2)
        end

        it "forgets the notifier it inherited when a reopen in the child raises before it connects" do
          tls_appender
          output = in_forked_child do
            tls_appender.url = "http://127.0.0.1:#{server.port}"
            tls_appender.reopen
            "reopened"
          rescue ArgumentError
            tls_appender.notifier.inspect
          end

          assert_equal "nil", output
        end
      end

      describe "#message_error?" do
        it "is true for a log message that GELF cannot send" do
          error = ArgumentError.new("Data too big (456404 bytes), would create more than 128 chunks!")

          assert appender.message_error?(error)
        end

        it "is false when the server is unavailable" do
          refute appender.message_error?(Errno::ECONNREFUSED.new)
        end
      end

      (SemanticLogger::LEVELS - %i[info warn error fatal]).each do |level|
        it "not send :#{level} notifications to Graylog" do
          hash = nil
          appender.notifier.stub(:notify!, ->(h) { hash = h }) do
            appender.send(level, "AppenderGraylogTest #{level} message")
          end

          assert_nil hash
        end
      end

      it "send exception notifications to Graylog with severity" do
        hash = nil
        exc  = nil
        begin
          Uh oh
        rescue Exception => e
          exc = e
        end
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.error "Reading File", exc
        end

        assert_equal "Reading File", hash[:short_message]
        assert_equal "NameError", hash[:exception][:name]
        assert_match "undefined local variable or method", hash[:exception][:message]
        assert_equal 3, hash[:level], "Should be error level (3)"
        assert_includes hash[:exception][:stack_trace].first, __FILE__, hash[:exception]
      end

      it "send exception notifications to Graylog without log message" do
        hash = nil
        exc  = nil
        begin
          raise StandardError, "Reading File"
        rescue Exception => e
          exc = e
        end
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.error exc
        end

        assert_equal exc.message, hash[:short_message]
        assert_equal exc.class.to_s, hash[:exception][:name]
        assert_match exc.message, hash[:exception][:message]
        assert_equal 3, hash[:level], "Should be error level (3)"
        assert_includes hash[:exception][:stack_trace].first, __FILE__, hash[:exception]
      end

      it "send notifications to Graylog without exception message" do
        hash = nil
        exc  = nil
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.error exc
        end

        assert_equal "<no-exception-message>", hash[:short_message]
        assert_nil exc
        assert_equal 3, hash[:level], "Should be error level (3)"
      end

      it "send error notifications to Graylog with severity" do
        hash = nil
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.error amessage
        end

        assert_equal amessage, hash[:short_message]
        assert_equal 3, hash[:level]
        refute hash[:stack_trace]
      end

      it "send notification to Graylog with custom attributes" do
        hash = nil
        appender.notifier.stub(:notify!, ->(h) { hash = h }) do
          appender.error amessage, key1: 1, key2: "a"
        end

        assert_equal amessage, hash[:short_message]
        assert_equal 3, hash[:level]
        refute hash[:stack_trace]
        assert payload = hash[:payload], hash
        assert_equal 1, payload[:key1], payload
        assert_equal "a", payload[:key2], payload
      end
    end
  end
end
