require_relative "../test_helper"
require 'tracer'

# Unit Test for Riemann
module Appender
  class Riemann < MiniTest::Test
    describe SemanticLogger::Appender::Riemann do
      before do
        @appender = SemanticLogger::Appender::Riemann.new()
        SemanticLogger.default_level = :info
        SemanticLogger.add_appender(appender: :riemann)
        SemanticLogger.application = "MiniTest"
        @logger = SemanticLogger['RiemannTest']
        # @reciever = Riemann::Client.new(host: "localhost", port: 5555, timeout: 5)
        #SemanticLogger.add_appender(appender: @appender)
        #@logger = SemanticLogger["RiemannTest"]
      end

      it "sends info" do
        @appender.send(:debug, "Halp!")
        #@logger.debug("Halp!")
      end
    end
  end
end
