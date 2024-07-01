require_relative "../test_helper"

# Unit Test for SemanticLogger::Appender::MongoDB
module Appender
  class MongoDBTest < Minitest::Test
    describe SemanticLogger::Appender::MongoDB do
      before do
        skip "Set env var MONGO_HOST to run Mongo tests" unless ENV["MONGO_HOST"]
      end

      let(:appender) do
        SemanticLogger::Appender::MongoDB.new(
          uri:             "mongodb://#{ENV['MONGO_HOST']}/test",
          collection_size: 10 * 1024**2,
          host:            "test",
          application:     "test_application",
          level:           :trace
        )
      end

      let(:ahash) { {tracking_number: 12_345, session_id: "HSSKLEU@JDK767"} }

      after do
        appender.purge_all
      end

      describe "format logs into documents" do
        it "handle no arguments" do
          appender.debug
          document = appender.collection.find.first
          assert_equal :debug, document["level"]
          assert_nil document["message"]
          assert_equal Thread.current.name, document["thread"]
          assert document["time"].is_a?(Time)
          assert_nil document["payload"]
          assert_equal $$, document["pid"]
          assert_equal "test", document["host"]
          assert_equal "test_application", document["application"]
        end

        it "handle named parameters" do
          appender.debug(payload: ahash)

          document = appender.collection.find.first
          assert_equal :debug, document["level"]
          assert_nil document["message"]
          assert_equal Thread.current.name, document["thread"]
          assert document["time"].is_a?(Time)
          assert payload = document["payload"]
          assert_equal 12_345, payload["tracking_number"], payload
          assert_equal "HSSKLEU@JDK767", payload["session_id"]
          assert_equal $$, document["pid"]
          assert_equal "test", document["host"]
          assert_equal "test_application", document["application"]
        end

        it "handle message and payload" do
          appender.debug("hello world", ahash)

          document = appender.collection.find.first
          assert_equal :debug, document["level"]
          assert_equal "hello world", document["message"]
          assert_equal Thread.current.name, document["thread"]
          assert document["time"].is_a?(Time)
          assert payload = document["payload"]
          assert_equal 12_345, payload["tracking_number"], payload
          assert_equal "HSSKLEU@JDK767", payload["session_id"]
          assert_equal $$, document["pid"]
          assert_equal "test", document["host"]
          assert_equal "test_application", document["application"]
        end

        it "handle message without payload" do
          appender.debug("hello world")

          document = appender.collection.find.first
          assert_equal :debug, document["level"]
          assert_equal "hello world", document["message"]
          assert_equal Thread.current.name, document["thread"]
          assert document["time"].is_a?(Time)
          assert_equal $$, document["pid"]
          assert_equal "test", document["host"]
          assert_equal "test_application", document["application"]
        end
      end

      # Ensure that any log level can be logged
      SemanticLogger::LEVELS.each do |level|
        describe "##{level}" do
          it "logs" do
            appender.send(level, "hello world -- Calculations", ahash)
            document = appender.collection.find.first
            assert_equal level, document["level"]
            assert_equal "hello world -- Calculations", document["message"]
            assert_equal Thread.current.name, document["thread"]
            assert document["time"].is_a?(Time)
            assert payload = document["payload"]
            assert_equal 12_345, payload["tracking_number"], payload
            assert_equal "HSSKLEU@JDK767", payload["session_id"]
            assert_equal $$, document["pid"]
            assert_equal "test", document["host"], document.ai
            assert_equal "test_application", document["application"]
          end
        end
      end
    end
  end
end
