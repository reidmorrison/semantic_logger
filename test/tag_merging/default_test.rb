require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class DefaultTagMergingTest < Minitest::Test
      describe "Default formatter tag merging" do
        let(:log_time) { Time.utc(2017, 1, 14, 8, 32, 5.375276) }
        let(:formatter) { SemanticLogger::Formatters::Default.new }

        def build_log(instance_tags: [], instance_named_tags: {}, tags: [], named_tags: {})
          log = SemanticLogger::Log.new("TagMergingTest", :info, nil, instance_tags, instance_named_tags)
          log.time = log_time
          log.tags = tags unless tags.empty?
          log.named_tags = named_tags unless named_tags.empty?
          log
        end

        describe "positional tags" do
          it "returns nil when no tags present" do
            log = build_log

            formatter.call(log, nil)

            assert_nil formatter.tags
          end

          it "formats thread tags only" do
            log = build_log(tags: %w[thread1 thread2])

            formatter.call(log, nil)

            assert_equal "[thread1] [thread2]", formatter.tags
          end

          it "formats instance tags only" do
            log = build_log(instance_tags: %w[instance1 instance2])

            formatter.call(log, nil)

            assert_equal "[instance1] [instance2]", formatter.tags
          end

          it "concatenates thread tags before instance tags" do
            log = build_log(
              tags: %w[thread1 thread2],
              instance_tags: %w[instance1 instance2]
            )

            formatter.call(log, nil)

            assert_equal "[thread1] [thread2] [instance1] [instance2]", formatter.tags
          end

          it "preserves duplicates when same tag in both sources" do
            log = build_log(
              tags: %w[shared unique-thread],
              instance_tags: %w[shared unique-instance]
            )

            formatter.call(log, nil)

            assert_equal "[shared] [unique-thread] [shared] [unique-instance]", formatter.tags
          end
        end

        describe "named tags" do
          it "returns nil when no named tags present" do
            log = build_log

            formatter.call(log, nil)

            assert_nil formatter.named_tags
          end

          it "formats thread named tags only" do
            log = build_log(named_tags: {request_id: "123", user: "alice"})

            formatter.call(log, nil)

            assert_equal "{request_id: 123, user: alice}", formatter.named_tags
          end

          it "formats instance named tags only" do
            log = build_log(instance_named_tags: {service: "api", version: "2.0"})

            formatter.call(log, nil)

            assert_equal "{service: api, version: 2.0}", formatter.named_tags
          end

          it "merges thread and instance named tags" do
            log = build_log(
              named_tags: {request_id: "123"},
              instance_named_tags: {service: "api"}
            )

            formatter.call(log, nil)

            assert_equal "{request_id: 123, service: api}", formatter.named_tags
          end

          it "instance named tags override thread named tags on conflict" do
            log = build_log(
              named_tags: {user: "thread-user", request_id: "123"},
              instance_named_tags: {user: "instance-user", service: "api"}
            )

            formatter.call(log, nil)

            assert_equal "{user: instance-user, request_id: 123, service: api}", formatter.named_tags
          end
        end
      end
    end
  end
end
