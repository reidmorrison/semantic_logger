require_relative "../test_helper"
require 'tracer'

# Unit Test for Riemann
module Appender
  class Riemann < MiniTest::Test
    describe SemanticLogger::Appender::Riemann do
      before do
        @appender = SemanticLogger::Appender::Riemann.new(riemann_server: "localhost:5555")
        SemanticLogger.default_level = :info
        SemanticLogger.add_appender(appender: @appender)
        SemanticLogger.application = "SomeApp"
        @logger = SemanticLogger["RiemannTest"]
      end

      it "sends info" do
        @logger.info("Halp!")
      end

      it "measures things" do
        @logger.measure_info("sleeping a tiny bit") do
          sleep 0.1
          42
        end
      end
    end
  end
end
