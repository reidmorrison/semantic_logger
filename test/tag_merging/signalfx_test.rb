require_relative "../test_helper"
require "json"

module SemanticLogger
  module Formatters
    class SignalfxTagMergingTest < Minitest::Test
      MOCK_LOGGER = Struct.new(:host, :application, :environment)

      describe "Signalfx formatter tag merging" do
        let(:log_time) { Time.utc(2017, 1, 14, 8, 32, 5.375276) }
        let(:formatter) do
          SemanticLogger::Formatters::Signalfx.new(
            token: "test-token",
            dimensions: %i[user request_id service],
            log_host: false,
            log_application: false,
            log_environment: false
          )
        end
        let(:logger) { MOCK_LOGGER.new("test_host", "test_app", "test") }

        def build_log(instance_tags: [], instance_named_tags: {}, tags: [], named_tags: {})
          log = SemanticLogger::Log.new("TagMergingTest", :info, nil, instance_tags, instance_named_tags)
          log.time = log_time
          log.metric = "/test/metric"
          log.tags = tags unless tags.empty?
          log.named_tags = named_tags unless named_tags.empty?
          log
        end

        def dimensions(log)
          result = JSON.parse(formatter.call(log, logger))
          result["counter"].first["dimensions"]
        end

        describe "named tags as dimensions" do
          it "excludes dimensions when no named tags present" do
            log = build_log

            dims = dimensions(log)

            refute dims.key?("user")
            refute dims.key?("request_id")
            refute dims.key?("service")
          end

          it "includes thread named tags matching dimensions" do
            log = build_log(named_tags: {request_id: "123", user: "alice"})

            dims = dimensions(log)

            assert_equal "123", dims["request_id"]
            assert_equal "alice", dims["user"]
          end

          it "includes instance named tags matching dimensions" do
            log = build_log(instance_named_tags: {service: "api", user: "bob"})

            dims = dimensions(log)

            assert_equal "api", dims["service"]
            assert_equal "bob", dims["user"]
          end

          it "merges thread and instance named tags as dimensions" do
            log = build_log(
              named_tags: {request_id: "123"},
              instance_named_tags: {service: "api"}
            )

            dims = dimensions(log)

            assert_equal "123", dims["request_id"]
            assert_equal "api", dims["service"]
          end

          it "instance named tags override thread named tags on conflict" do
            log = build_log(
              named_tags: {user: "thread-user", request_id: "123"},
              instance_named_tags: {user: "instance-user", service: "api"}
            )

            dims = dimensions(log)

            assert_equal "instance-user", dims["user"]
            assert_equal "123", dims["request_id"]
            assert_equal "api", dims["service"]
          end
        end
      end
    end
  end
end
