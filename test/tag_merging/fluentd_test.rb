require_relative "../test_helper"
require "json"

module SemanticLogger
  module Formatters
    class FluentdTagMergingTest < Minitest::Test
      describe "Fluentd formatter tag merging" do
        let(:log_time) { Time.utc(2017, 1, 14, 8, 32, 5.375276) }
        let(:formatter) { SemanticLogger::Formatters::Fluentd.new(log_host: false, log_application: false, log_environment: false) }

        def build_log(instance_tags: [], instance_named_tags: {}, tags: [], named_tags: {})
          log = SemanticLogger::Log.new("TagMergingTest", :info, nil, instance_tags, instance_named_tags)
          log.time = log_time
          log.tags = tags unless tags.empty?
          log.named_tags = named_tags unless named_tags.empty?
          log
        end

        def parsed_result(log)
          JSON.parse(formatter.call(log, nil), symbolize_names: true)
        end

        describe "positional tags" do
          it "omits tags key when no tags present" do
            log = build_log

            result = parsed_result(log)

            refute result.key?(:tags)
          end

          it "returns thread tags only" do
            log = build_log(tags: %w[thread1 thread2])

            result = parsed_result(log)

            assert_equal %w[thread1 thread2], result[:tags]
          end

          it "returns instance tags only" do
            log = build_log(instance_tags: %w[instance1 instance2])

            result = parsed_result(log)

            assert_equal %w[instance1 instance2], result[:tags]
          end

          it "concatenates thread tags before instance tags" do
            log = build_log(
              tags: %w[thread1 thread2],
              instance_tags: %w[instance1 instance2]
            )

            result = parsed_result(log)

            assert_equal %w[thread1 thread2 instance1 instance2], result[:tags]
          end

          it "preserves duplicates when same tag in both sources" do
            log = build_log(
              tags: %w[shared unique-thread],
              instance_tags: %w[shared unique-instance]
            )

            result = parsed_result(log)

            assert_equal %w[shared unique-thread shared unique-instance], result[:tags]
          end
        end

        describe "named tags" do
          it "omits named_tags key when no named tags present" do
            log = build_log

            result = parsed_result(log)

            refute result.key?(:named_tags)
          end

          it "returns thread named tags only" do
            log = build_log(named_tags: {request_id: "123", user: "alice"})

            result = parsed_result(log)

            assert_equal({request_id: "123", user: "alice"}, result[:named_tags])
          end

          it "returns instance named tags only" do
            log = build_log(instance_named_tags: {service: "api", version: "2.0"})

            result = parsed_result(log)

            assert_equal({service: "api", version: "2.0"}, result[:named_tags])
          end

          it "merges thread and instance named tags" do
            log = build_log(
              named_tags: {request_id: "123"},
              instance_named_tags: {service: "api"}
            )

            result = parsed_result(log)

            assert_equal({request_id: "123", service: "api"}, result[:named_tags])
          end

          it "instance named tags override thread named tags on conflict" do
            log = build_log(
              named_tags: {user: "thread-user", request_id: "123"},
              instance_named_tags: {user: "instance-user", service: "api"}
            )

            result = parsed_result(log)

            assert_equal({user: "instance-user", request_id: "123", service: "api"}, result[:named_tags])
          end
        end
      end
    end
  end
end
