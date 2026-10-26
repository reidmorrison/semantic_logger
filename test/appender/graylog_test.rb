require_relative "../test_helper"

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

      it "hands GELF the formatted Hash itself, without copying it, when JSON can write it" do
        hash = nil
        SemanticLogger::Utils.stub(:json_safe, ->(*) { flunk "must not copy a Hash that JSON can write" }) do
          appender.notifier.stub(:notify!, ->(h) { hash = h }) do
            appender.info("Hello", user: "jack")
          end
        end

        assert_equal "Hello", hash[:short_message]
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
