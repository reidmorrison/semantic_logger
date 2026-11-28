require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::Bugsnag
module Appender
  class BugsnagTest < Minitest::Test
    describe SemanticLogger::Appender::Bugsnag do
      let(:appender) { SemanticLogger::Appender::Bugsnag.new(level: :info) }
      let(:log_message) { "AppenderBugsnagTest log message" }

      SemanticLogger::LEVELS.each do |level|
        it "sends #{level} message" do
          bugsnag_level =
            case level
            when :warn
              "warning"
            when :fatal
              "error"
            else
              level.to_s
            end
          exception, hash, severity = stub_bugsnag do
            appender.send(level, log_message)
          end
          if %i[trace debug].include?(level)
            assert_nil exception
            assert_nil hash
          else
            assert_equal "RuntimeError", exception.class.to_s
            assert_equal log_message, exception.message
            assert_equal bugsnag_level.to_s, severity
          end
        end

        it "sends #{level} custom attributes" do
          exception, hash, _severity = stub_bugsnag do
            appender.send(level, log_message, key1: 1, key2: "a")
          end
          if %i[trace debug].include?(level)
            assert_nil exception
            assert_nil hash
          else
            assert_equal "RuntimeError", exception.class.to_s
            assert_equal log_message, exception.message
            assert payload = hash[:payload], hash
            assert_equal 1, payload[:key1], payload
            assert_equal "a", payload[:key2], payload
          end
        end

        it "sends #{level} exceptions" do
          error = RuntimeError.new("Hello World")
          exception, hash, _severity = stub_bugsnag do
            appender.send(level, log_message, error)
          end
          if %i[trace debug].include?(level)
            assert_nil exception
            assert_nil hash
          else
            assert_equal error.class.to_s, exception.class.to_s
            assert_equal error.message, exception.message
            assert_equal log_message, hash[:message], hash
          end
        end

        # Bugsnag replaces each byte that is not valid UTF-8 with U+FFFD.
        it "sends binary text as UTF-8, keeping its characters" do
          exception, hash, _severity = stub_bugsnag do
            appender.error("Café ☕".b, body: "Café \xFF☕".b)
          end

          assert_equal "Café ☕", exception.message
          assert_equal "Café ☕", hash[:payload][:body]
          assert_equal "Café ☕", hash[:message]
        end

        it "sends a payload that holds itself, cut off where it repeats" do
          payload        = {name: "loop", body: "Café".b}
          payload[:self] = payload
          _exception, hash, _severity = stub_bugsnag { appender.error("Looped", payload) }

          assert_equal "Café", hash[:payload][:body]
          assert_equal "#<Hash nested too deeply>", hash[:payload][:self][:self]
        end

        # Bugsnag cleans any other object itself, writing a Struct as "[OBJECT]".
        it "sends a payload object, such as a Struct, as it is" do
          credentials = Struct.new(:user, :api_key).new("bob", "k-123")
          _exception, hash, _severity = stub_bugsnag do
            appender.error("Charge failed", creds: credentials, body: "Café".b)
          end

          assert_same credentials, hash[:payload][:creds]
          assert_equal "Café", hash[:payload][:body]
        end

        it "does not send metric only notifications" do
          exception, hash, severity = stub_bugsnag do
            appender.debug metric: "my/custom/metric", payload: {hello: :world}
          end

          assert_nil exception
          assert_nil hash
          assert_nil severity
        end
      end

      it "sends an exception whose #message raises" do
        error = ExceptionFixtures::BrokenMessageError.new("Order 7")
        exception, hash, _severity = stub_bugsnag { appender.error("Could not save", error) }

        assert_same error, exception
        assert_equal "Could not save", hash[:message]
      end

      it "sends the backtrace of the code that logged an entry without an exception" do
        exception, _hash, _severity = stub_bugsnag do
          through(appender) { |logger| logger.error(log_message) }
        end

        assert_match(/bugsnag_test\.rb:\d+/, exception.backtrace.first)
      end

      it "sends the backtrace of the code that logged an exception that was never raised" do
        error = RuntimeError.new("Never raised")
        exception, _hash, _severity = stub_bugsnag do
          through(appender) { |logger| logger.error(log_message, error) }
        end

        assert_same error, exception
        assert_match(/bugsnag_test\.rb:\d+/, exception.backtrace.first)
      end

      it "makes its backtrace capture shareable, so that it runs in other Ractors too" do
        skip "Ractors are not supported" unless defined?(Ractor.shareable?)

        assert Ractor.shareable?(SemanticLogger::Appender::Bugsnag::CAPTURE_BACKTRACE)
      end

      def stub_bugsnag(&block)
        exception = hash = level = nil
        appender.stub(:bugsnag_notify, lambda { |exc, h, l|
          exception = exc
          hash = h
          level = l
        }, &block)
        [exception, hash, level]
      end
    end
  end
end
