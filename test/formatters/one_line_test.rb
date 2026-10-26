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

        describe "tags" do
          it "strips line breaks from tags" do
            log.tags = ["t\nforged", "u\rv"]

            assert_equal "[tforged] [uv]", formatter.tags
          end

          it "escapes tags once when escape_control_chars is enabled" do
            log.tags  = ["t\nforged\e[2K"]
            formatter = SemanticLogger::Formatters::OneLine.new(escape_control_chars: true)
            formatter.call(log, nil)

            assert_equal "[t\\nforged\\e[2K]", formatter.tags
          end
        end

        describe "named_tags" do
          it "strips line breaks from named tag names and values" do
            log.named_tags = {"k\n": "v\rX", id: 12}

            assert_equal "{k: vX, id: 12}", formatter.named_tags
          end

          it "escapes named tags once when escape_control_chars is enabled" do
            log.named_tags = {k: "v\r\nX"}
            formatter      = SemanticLogger::Formatters::OneLine.new(escape_control_chars: true)
            formatter.call(log, nil)

            assert_equal "{k: v\\r\\nX}", formatter.named_tags
          end
        end

        describe "name" do
          it "strips line breaks from the name" do
            log.name = "Class\nforged"

            assert_equal "Classforged", formatter.name
          end
        end

        describe "thread_name" do
          it "strips line breaks from the thread name" do
            log.thread_name = "worker\r\nforged"

            assert_equal "workerforged", formatter.thread_name
          end
        end

        describe "payload" do
          it "strips line breaks from a payload whose inspect spans lines" do
            value = Object.new
            def value.inspect = "multi\nline"
            log.payload = {value: value}

            refute_includes formatter.payload, "\n"
          end
        end

        describe "call" do
          it "keeps the whole entry on one line" do
            log.message    = "msg\nforged"
            log.tags       = ["t\nforged"]
            log.named_tags = {k: "v\rX"}
            log.name       = "Name\n"
            log.payload    = {a: "b\nc"}
            set_exception
            output = SemanticLogger::Formatters::OneLine.new.call(log, nil)

            refute_match(/[\r\n]/, output)
          end
        end
      end
    end
  end
end
