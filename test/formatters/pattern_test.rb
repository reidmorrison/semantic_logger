require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class PatternTest < Minitest::Test
      describe Pattern do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) { :debug }

        let(:log) do
          log         = SemanticLogger::Log.new("PatternTest", level)
          log.time    = log_time
          log.message = "Hello World"
          log
        end

        def formatted(pattern, log_entry = log, logger = nil)
          Pattern.new(pattern: pattern).call(log_entry, logger)
        end

        describe "directives" do
          it "interpolates the message" do
            assert_equal "Hello World", formatted("%{message}")
          end

          it "interpolates the level" do
            assert_equal "debug", formatted("%{level}")
          end

          it "interpolates the name" do
            assert_equal "PatternTest", formatted("%{name}")
          end

          it "interpolates the time" do
            assert_equal "2017-01-14 08:32:05.375276", formatted("%{time}")
          end

          it "combines several directives with literal text" do
            assert_equal "debug PatternTest -- Hello World",
                         formatted("%{level} %{name} -- %{message}")
          end
        end

        describe "named tags" do
          let(:log) do
            log            = SemanticLogger::Log.new("PatternTest", level)
            log.time       = log_time
            log.message    = "Hello World"
            log.named_tags = {request_id: "abc123", user: "jack"}
            log
          end

          it "interpolates a single named tag by key" do
            assert_equal "abc123", formatted("%{named_tags:request_id}")
          end

          it "interpolates all named tags when no key is given" do
            assert_equal "request_id: abc123, user: jack", formatted("%{named_tags}")
          end
        end

        describe "escaping" do
          it "emits a literal %{...} for %%{...}" do
            assert_equal "%{message}", formatted("%%{message}")
          end
        end

        describe "duration" do
          let(:log) do
            log          = SemanticLogger::Log.new("PatternTest", level)
            log.time     = log_time
            log.duration = 1234.567
            log
          end

          it "renders a human readable duration without parentheses" do
            assert_equal "1.235s", formatted("%{duration}")
          end

          it "renders the numeric duration in milliseconds" do
            assert_equal "1234.567", formatted("%{duration_ms}")
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
