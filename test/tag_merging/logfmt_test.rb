require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class LogfmtTagMergingTest < Minitest::Test
      describe "Logfmt formatter tag merging" do
        let(:log_time) { Time.utc(2017, 1, 14, 8, 32, 5.375276) }
        let(:formatter) { SemanticLogger::Formatters::Logfmt.new(log_host: false, log_application: false, log_environment: false) }

        def build_log(instance_tags: [], instance_named_tags: {}, tags: [], named_tags: {})
          log = SemanticLogger::Log.new("TagMergingTest", :info, nil, instance_tags, instance_named_tags)
          log.time = log_time
          log.tags = tags unless tags.empty?
          log.named_tags = named_tags unless named_tags.empty?
          log
        end

        describe "positional tags" do
          it "includes thread tags as boolean keys" do
            log = build_log(tags: %w[thread1 thread2])

            result = formatter.call(log, nil)

            assert_includes result, "thread1=true"
            assert_includes result, "thread2=true"
          end

          it "includes instance tags as boolean keys" do
            log = build_log(instance_tags: %w[instance1 instance2])

            result = formatter.call(log, nil)

            assert_includes result, "instance1=true"
            assert_includes result, "instance2=true"
          end

          it "includes both thread and instance tags" do
            log = build_log(
              tags: %w[thread1],
              instance_tags: %w[instance1]
            )

            result = formatter.call(log, nil)

            assert_includes result, "thread1=true"
            assert_includes result, "instance1=true"
          end
        end

        describe "named tags" do
          it "includes thread named tags" do
            log = build_log(named_tags: {request_id: "123", user: "alice"})

            result = formatter.call(log, nil)

            assert_includes result, "request_id=\"123\""
            assert_includes result, "user=\"alice\""
          end

          it "includes instance named tags" do
            log = build_log(instance_named_tags: {service: "api", version: "2.0"})

            result = formatter.call(log, nil)

            assert_includes result, "service=\"api\""
            assert_includes result, "version=\"2.0\""
          end

          it "merges thread and instance named tags" do
            log = build_log(
              named_tags: {request_id: "123"},
              instance_named_tags: {service: "api"}
            )

            result = formatter.call(log, nil)

            assert_includes result, "request_id=\"123\""
            assert_includes result, "service=\"api\""
          end

          it "instance named tags override thread named tags on conflict" do
            log = build_log(
              named_tags: {user: "thread-user", request_id: "123"},
              instance_named_tags: {user: "instance-user", service: "api"}
            )

            result = formatter.call(log, nil)

            assert_includes result, "user=\"instance-user\""
            refute_includes result, "thread-user"
          end
        end
      end
    end
  end
end
