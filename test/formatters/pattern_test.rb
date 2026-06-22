require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class PatternTest < Minitest::Test
      describe Pattern do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) { :debug }

        let(:backtrace) do
          [
            "test/formatters/pattern_test.rb:42:in `block (2 levels) in <class:PatternTest>'",
            "lib/minitest/spec.rb:247:in `instance_eval'"
          ]
        end

        # A minimal stand-in for an appender, which is what Pattern reads
        # host / application / environment from.
        let(:logger) do
          Struct.new(:host, :application, :environment).new("myhost", "myapp", "myenv")
        end

        let(:log) do
          log         = SemanticLogger::Log.new("PatternTest", level)
          log.time    = log_time
          log.message = "Hello World"
          log
        end

        def formatted(pattern, log_entry = log, logger_entry = nil)
          Pattern.new(pattern: pattern).call(log_entry, logger_entry)
        end

        describe "time" do
          it "interpolates the formatted time" do
            assert_equal "2017-01-14 08:32:05.375276", formatted("%{time}")
          end
        end

        describe "level" do
          it "interpolates the full level name" do
            assert_equal "debug", formatted("%{level}")
          end
        end

        describe "level_short" do
          it "interpolates the single character level" do
            assert_equal "D", formatted("%{level_short}")
          end
        end

        describe "name" do
          it "interpolates the logger name" do
            assert_equal "PatternTest", formatted("%{name}")
          end
        end

        describe "message" do
          it "interpolates the message" do
            assert_equal "Hello World", formatted("%{message}")
          end

          it "is blank when there is no message" do
            log.message = nil

            assert_equal "", formatted("%{message}")
          end
        end

        describe "payload" do
          it "interpolates the payload" do
            log.payload = {foo: "bar"}

            assert_equal({foo: "bar"}.inspect, formatted("%{payload}"))
          end

          it "is blank when there is no payload" do
            assert_equal "", formatted("%{payload}")
          end
        end

        describe "exception" do
          it "interpolates the exception class and message" do
            begin
              raise "Oh no"
            rescue StandardError => e
              log.exception = e
            end

            assert_includes formatted("%{exception}"), "RuntimeError: Oh no"
          end

          it "is blank when there is no exception" do
            assert_equal "", formatted("%{exception}")
          end
        end

        describe "duration" do
          it "renders a human readable duration without parentheses" do
            log.duration = 1234.567

            assert_equal "1.235s", formatted("%{duration}")
          end

          it "is blank when there is no duration" do
            assert_equal "", formatted("%{duration}")
          end
        end

        describe "duration_ms" do
          it "renders the numeric duration in milliseconds" do
            log.duration = 1234.567

            assert_equal "1234.567", formatted("%{duration_ms}")
          end
        end

        describe "thread_name" do
          it "interpolates the thread name" do
            log.thread_name = "worker-1"

            assert_equal "worker-1", formatted("%{thread_name}")
          end
        end

        describe "pid" do
          it "interpolates the process id" do
            assert_equal $$.to_s, formatted("%{pid}")
          end
        end

        describe "file_name_and_line" do
          it "interpolates the file name and line from the backtrace" do
            log.backtrace = backtrace

            assert_equal "pattern_test.rb:42", formatted("%{file_name_and_line}")
          end

          it "is blank without a backtrace" do
            assert_equal "", formatted("%{file_name_and_line}")
          end
        end

        describe "tags" do
          it "interpolates comma separated tags" do
            log.tags = %w[alpha beta]

            assert_equal "alpha, beta", formatted("%{tags}")
          end

          it "is blank when there are no tags" do
            log.tags = []

            assert_equal "", formatted("%{tags}")
          end
        end

        describe "named_tags" do
          before do
            log.named_tags = {request_id: "abc123", user: "jack"}
          end

          it "interpolates a single named tag by key" do
            assert_equal "abc123", formatted("%{named_tags:request_id}")
          end

          it "interpolates all named tags when no key is given" do
            assert_equal "request_id: abc123, user: jack", formatted("%{named_tags}")
          end

          it "is blank when there are no named tags" do
            log.named_tags = {}

            assert_equal "", formatted("%{named_tags}")
          end
        end

        describe "host" do
          it "interpolates the appender host" do
            assert_equal "myhost", formatted("%{host}", log, logger)
          end
        end

        describe "application" do
          it "interpolates the appender application" do
            assert_equal "myapp", formatted("%{application}", log, logger)
          end
        end

        describe "environment" do
          it "interpolates the appender environment" do
            assert_equal "myenv", formatted("%{environment}", log, logger)
          end
        end

        describe "combining directives" do
          it "combines several directives with literal text" do
            assert_equal "debug PatternTest -- Hello World",
                         formatted("%{level} %{name} -- %{message}")
          end
        end

        describe "escaping" do
          it "emits a literal %{...} for %%{...}" do
            assert_equal "%{message}", formatted("%%{message}")
          end
        end

        describe "errors" do
          it "raises on an unknown directive at construction time" do
            assert_raises(ArgumentError) { Pattern.new(pattern: "%{nope}") }
          end

          it "raises when a non-parameterized directive is given an argument" do
            assert_raises(ArgumentError) { Pattern.new(pattern: "%{message:foo}") }
          end
        end

        describe "default pattern" do
          it "produces output similar to the Default formatter" do
            result = Pattern.new.call(log, nil)

            assert_includes result, "debug"
            assert_includes result, "PatternTest"
            assert_includes result, "-- Hello World"
          end
        end
      end
    end
  end
end
