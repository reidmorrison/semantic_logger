require_relative "../test_helper"

module SemanticLogger
  module Otlp
    class ResourceTest < Minitest::Test
      describe Resource do
        let(:env) { {} }
        let(:otel) do
          Environment.new(SemanticLogger::Processor.logger, Signal::LOGS).tap do |otel|
            env_vars = env
            otel.define_singleton_method(:value) { |name| env_vars[name] }
          end
        end
        let(:defaults) { {application: "default_app", host: "default_host", environment: nil} }

        def resource(**args)
          Resource.new(otel: otel, defaults: defaults, **args)
        end

        it "names the defaults, leaving out a nil environment" do
          assert_equal({"service.name" => "default_app", "host.name" => "default_host"}, resource.attributes)
        end

        it "lets OTEL_RESOURCE_ATTRIBUTES replace the defaults" do
          env["OTEL_RESOURCE_ATTRIBUTES"] = "service.name=from_env,team=core"

          assert_equal "from_env", resource.attributes["service.name"]
          assert_equal "core", resource.attributes["team"]
        end

        it "lets the values given, and OTEL_SERVICE_NAME, replace the environment's attributes" do
          env["OTEL_RESOURCE_ATTRIBUTES"] = "service.name=from_env,host.name=env_host"
          env["OTEL_SERVICE_NAME"]        = "service"

          attributes = resource(given: {host: "given_host", environment: "production"}).attributes

          assert_equal "service", attributes["service.name"]
          assert_equal "given_host", attributes["host.name"]
          assert_equal "production", attributes["deployment.environment.name"]
        end

        it "prefers an application given to OTEL_SERVICE_NAME" do
          env["OTEL_SERVICE_NAME"] = "service"

          assert_equal "given", resource(given: {application: "given"}).attributes["service.name"]
        end

        it "lets the attributes given replace all the others" do
          attributes = resource(given: {application: "given"}, attributes: {"service.name": "extra", v: 1}).attributes

          assert_equal "extra", attributes["service.name"]
          assert_equal 1, attributes["v"]
        end

        it "leaves out the process.pid of OTEL_RESOURCE_ATTRIBUTES, with a warning" do
          env["OTEL_RESOURCE_ATTRIBUTES"] = "process.pid=1"
          logger = Minitest::Mock.new
          logger.expect(:warn, nil, [/process.pid/])

          refute resource(logger: logger).attributes.key?("process.pid")
          logger.verify
        end

        it "adds the pid of the process to its process attributes, unless given one" do
          assert_equal ::Process.pid, resource.process_attributes["process.pid"]
          assert_equal 42, resource(attributes: {"process.pid" => 42}).process_attributes["process.pid"]
          refute resource.attributes.key?("process.pid")
        end

        it "is frozen" do
          assert_predicate resource.attributes, :frozen?
        end
      end
    end
  end
end
