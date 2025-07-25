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

        it "does not send metric only notifications" do
          exception, hash, severity = stub_bugsnag do
            appender.debug metric: "my/custom/metric", payload: {hello: :world}
          end
          assert_nil exception
          assert_nil hash
          assert_nil severity
        end
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
