require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class DefaultTest < Minitest::Test
      describe Default do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          log      = SemanticLogger::Log.new("DefaultTest", level)
          log.time = log_time
          log
        end

        let(:set_exception) do
          raise "Oh no"
        rescue Exception => e
          log.exception = e
        end

        let(:formatter) do
          formatter = SemanticLogger::Formatters::OneLine.new
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        describe "message" do
          it "logs message" do
            log.message = "Hello \nWorld\n"

            assert_equal "-- Hello World", formatter.message
          end

          it "skips empty message" do
            refute formatter.message
          end

          it "strips carriage returns, which could overwrite the displayed line" do
            log.message = "user=bob\ruser=admin"

            assert_equal "-- user=bobuser=admin", formatter.message
          end

          it "escapes control characters when escape_control_chars is enabled" do
            log.message = "user=bob\r\e[2Kuser=admin\nforged"
            formatter   = SemanticLogger::Formatters::OneLine.new(escape_control_chars: true)
            formatter.call(log, nil)

            assert_equal "-- user=bob\\r\\e[2Kuser=admin\\nforged", formatter.message
          end
        end

        describe "exception" do
          it "logs exception" do
            set_exception

            assert_equal "-- Exception: RuntimeError: Oh no", formatter.exception
          end

          it "skips nil exception" do
            refute formatter.exception
          end

          it "escapes control characters in the exception message when enabled" do
            begin
              raise "Oh\e[31m no\nforged"
            rescue StandardError => e
              log.exception = e
            end
            formatter = SemanticLogger::Formatters::OneLine.new(escape_control_chars: true)
            formatter.call(log, nil)

            assert_equal "-- Exception: RuntimeError: Oh\\e[31m no\\nforged", formatter.exception
          end
        end
      end
    end
  end
end
