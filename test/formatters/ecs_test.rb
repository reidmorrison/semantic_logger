require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class EcsTest < Minitest::Test
      describe Ecs do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:level) do
          :debug
        end

        let(:log) do
          log      = SemanticLogger::Log.new("EcsTest", level)
          log.time = log_time
          log
        end

        # Stand-in for the appender / subscriber that owns host/application/environment.
        let(:appender) do
          Struct.new(:host, :application, :environment).new("test_host", "test_app", "test_env")
        end

        let(:formatter) do
          SemanticLogger::Formatters::Ecs.new
        end

        let(:result) do
          JSON.parse(formatter.call(log, appender), symbolize_names: true)
        end

        describe "core fields" do
          it "emits an ISO-8601 @timestamp" do
            assert_equal "2017-01-14T08:32:05.375276Z", result[:@timestamp]
          end

          it "emits the ecs version" do
            assert_equal SemanticLogger::Formatters::Ecs::ECS_VERSION, result.dig(:ecs, :version)
          end

          it "emits the level and logger name" do
            assert_equal "debug", result.dig(:log, :level)
            assert_equal "EcsTest", result.dig(:log, :logger)
          end

          it "emits the message" do
            log.message = "Hello World"

            assert_equal "Hello World", result[:message]
          end
        end

        describe "process, host, service" do
          it "maps pid and thread name under process" do
            assert_kind_of Integer, result.dig(:process, :pid)
            assert_equal Thread.current.name.to_s, result.dig(:process, :thread, :name) if Thread.current.name
          end

          it "maps host to host.hostname" do
            assert_equal "test_host", result.dig(:host, :hostname)
          end

          it "maps application and environment to service" do
            assert_equal "test_app", result.dig(:service, :name)
            assert_equal "test_env", result.dig(:service, :environment)
          end
        end

        describe "duration" do
          it "converts milliseconds to event.duration in nanoseconds" do
            log.duration = 1.5

            assert_equal 1_500_000, result.dig(:event, :duration)
          end

          it "omits event.duration when not set" do
            refute result.key?(:event)
          end
        end

        describe "tags and named_tags" do
          it "emits tags as a top-level array" do
            log.tags = %w[first second]

            assert_equal %w[first second], result[:tags]
          end

          it "maps named_tags to labels" do
            log.named_tags = {user_id: 5, account: "acme"}

            assert_equal({user_id: 5, account: "acme"}, result[:labels])
          end

          it "omits labels when empty" do
            refute result.key?(:labels)
          end
        end

        describe "exception" do
          it "maps to error.type / error.message / error.stack_trace" do
            begin
              raise "Oh no"
            rescue StandardError => e
              log.exception = e
            end

            assert_equal "RuntimeError", result.dig(:error, :type)
            assert_equal "Oh no", result.dig(:error, :message)
            assert_kind_of String, result.dig(:error, :stack_trace)
          end

          it "omits error when not set" do
            refute result.key?(:error)
          end
        end

        describe "namespace for non-ECS data" do
          it "nests payload, metric, and metric_amount under the default namespace" do
            log.payload       = {first: 1, second: 2}
            log.metric        = "users/registered"
            log.metric_amount = 3

            assert_equal({first: 1, second: 2}, result.dig(:semantic_logger, :payload))
            assert_equal "users/registered", result.dig(:semantic_logger, :metric)
            assert_equal 3, result.dig(:semantic_logger, :metric_amount)
          end

          it "uses a custom namespace" do
            formatter = SemanticLogger::Formatters::Ecs.new(namespace: "my_app")
            log.payload = {first: 1}
            parsed = JSON.parse(formatter.call(log, appender), symbolize_names: true)

            assert_equal({first: 1}, parsed.dig(:my_app, :payload))
          end

          it "merges payload into labels when namespace is nil" do
            formatter = SemanticLogger::Formatters::Ecs.new(namespace: nil)
            log.payload    = {first: 1}
            log.named_tags = {user_id: 5}
            parsed = JSON.parse(formatter.call(log, appender), symbolize_names: true)

            assert_equal 1, parsed.dig(:labels, :payload, :first)
            assert_equal 5, parsed.dig(:labels, :user_id)
            refute parsed.key?(:semantic_logger)
          end

          it "omits the namespace when there is no extra data" do
            refute result.key?(:semantic_logger)
          end
        end

        describe "JSON encoding" do
          it "returns a single line of valid JSON" do
            log.message    = "Hello World"
            log.payload    = {first: 1}
            log.named_tags = {user_id: 5}

            json = formatter.call(log, appender)

            assert_kind_of String, json
            refute_includes json, "\n"

            parsed = JSON.parse(json)

            assert_equal "Hello World", parsed["message"]
            assert_equal SemanticLogger::Formatters::Ecs::ECS_VERSION, parsed.dig("ecs", "version")
            assert_equal 1, parsed.dig("semantic_logger", "payload", "first")
            assert_equal 5, parsed.dig("labels", "user_id")
          end

          it "batches events into a JSON array" do
            json = formatter.batch([log, log], appender)
            parsed = JSON.parse(json)

            assert_equal 2, parsed.size
            assert_equal "debug", parsed.first.dig("log", "level")
          end
        end
      end
    end
  end
end
