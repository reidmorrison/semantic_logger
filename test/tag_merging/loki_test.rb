require_relative "../test_helper"
require "json"

module SemanticLogger
  module Formatters
    class LokiTagMergingTest < Minitest::Test
      MOCK_LOGGER = Struct.new(:host, :application, :name, :environment)

      describe "Loki formatter tag merging" do
        let(:log_time) { Time.utc(2017, 1, 14, 8, 32, 5.375276) }
        let(:formatter) { SemanticLogger::Formatters::Loki.new }
        let(:logger) { MOCK_LOGGER.new("test_host", "test_app", "TestLogger", "test") }

        def build_log(instance_tags: [], instance_named_tags: {}, tags: [], named_tags: {})
          log = SemanticLogger::Log.new("TagMergingTest", :info, nil, instance_tags, instance_named_tags)
          log.time = log_time
          log.thread_name = "test-thread"
          log.message = "test message"
          log.tags = tags unless tags.empty?
          log.named_tags = named_tags unless named_tags.empty?
          log
        end

        def stream_data(log)
          JSON.parse(formatter.call(log, logger))["streams"].first["stream"]
        end

        describe "positional tags" do
          it "omits tags key when no tags present" do
            log = build_log

            result = stream_data(log)

            refute result.key?("tags")
          end

          it "returns thread tags only" do
            log = build_log(tags: %w[thread1 thread2])

            result = stream_data(log)

            assert_equal %w[thread1 thread2], result["tags"]
          end

          it "returns instance tags only" do
            log = build_log(instance_tags: %w[instance1 instance2])

            result = stream_data(log)

            assert_equal %w[instance1 instance2], result["tags"]
          end

          it "concatenates thread tags before instance tags" do
            log = build_log(
              tags: %w[thread1 thread2],
              instance_tags: %w[instance1 instance2]
            )

            result = stream_data(log)

            assert_equal %w[thread1 thread2 instance1 instance2], result["tags"]
          end

          it "preserves duplicates when same tag in both sources" do
            log = build_log(
              tags: %w[shared unique-thread],
              instance_tags: %w[shared unique-instance]
            )

            result = stream_data(log)

            assert_equal %w[shared unique-thread shared unique-instance], result["tags"]
          end
        end

        describe "named tags" do
          it "omits named tag keys when no named tags present" do
            log = build_log

            result = stream_data(log)

            refute result.key?("request_id")
            refute result.key?("user")
          end

          it "returns thread named tags only" do
            log = build_log(named_tags: {request_id: "123", user: "alice"})

            result = stream_data(log)

            assert_equal "123", result["request_id"]
            assert_equal "alice", result["user"]
          end

          it "returns instance named tags only" do
            log = build_log(instance_named_tags: {service: "api", version: "2.0"})

            result = stream_data(log)

            assert_equal "api", result["service"]
            assert_equal "2.0", result["version"]
          end

          it "merges thread and instance named tags" do
            log = build_log(
              named_tags: {request_id: "123"},
              instance_named_tags: {service: "api"}
            )

            result = stream_data(log)

            assert_equal "123", result["request_id"]
            assert_equal "api", result["service"]
          end

          it "instance named tags override thread named tags on conflict" do
            log = build_log(
              named_tags: {user: "thread-user", request_id: "123"},
              instance_named_tags: {user: "instance-user", service: "api"}
            )

            result = stream_data(log)

            assert_equal "instance-user", result["user"]
            assert_equal "123", result["request_id"]
            assert_equal "api", result["service"]
          end
        end
      end
    end
  end
end
