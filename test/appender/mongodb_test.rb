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
          uri:             "mongodb://#{ENV.fetch('MONGO_HOST', nil)}/test",
          collection_size: 10 * (1024**2),
          host:            "test",
          application:     "test_application",
          level:           :trace,
          # Acknowledged writes, so that a test can read back what it just logged. The default of
          # 0 does not wait for the server, which made the tests fail now and then.
          write_concern:   1
        )
      end

      let(:ahash) { {tracking_number: 12_345, session_id: "HSSKLEU@JDK767"} }
      # Worked out independently of Log.thread_name_for, so that these assertions catch a
      # regression in it.
      let(:thread_name) { Thread.current.name || Thread.current.object_id.to_s }

      after do
        appender.purge_all
      end

      describe "#message_error?" do
        it "is true for a document that BSON cannot serialize" do
          [{big: 2**64}, {object: Object.new}, {pattern: Regexp.new("a\0b")}].each do |payload|
            error = assert_raises(StandardError) { appender.info("Webhook received", payload: payload) }

            assert appender.message_error?(error), "expected #{error.class} to be a message error"
          end
        end

        it "is false when the server is unavailable" do
          refute appender.message_error?(Mongo::Error::NoServerAvailable.allocate)
        end

        it "is false for a reply from the server that cannot be decoded" do
          refute appender.message_error?(BSON::Error::BSONDecodeError.new("invalid reply"))
        end
      end

      # BSON stores only valid UTF-8 text, and keys without NUL bytes.
      describe "text that BSON refuses" do
        it "stores the entry, with its text converted to valid UTF-8" do
          appender.error(
            "Webhook \xFF failed".b,
            payload:   {
              body:                                    "Café ☕".b,
              "clé".encode(Encoding::ISO_8859_1)       => "latin",
              "a\u0000b"                               => "nul",
              "Café".b.to_sym                          => "symbol",
              ascii: "Café".dup.force_encoding(Encoding::US_ASCII)
            },
            exception: RuntimeError.new((+"quoted \xFF input").force_encoding(Encoding::UTF_8))
          )
          document = appender.collection.find.first

          assert_equal "Webhook  failed", document["message"]
          assert_equal(
            {"body" => "Café ☕", "clé" => "latin", "ab" => "nul", "Café" => "symbol", "ascii" => "Café"},
            document["payload"]
          )
          assert_equal "quoted  input", document["exception"]["message"]
        end

        # BSON's own serializer overflows the stack, killing the process, when it reaches a
        # structure that holds itself, so the binary body must come before it.
        it "stores a document that holds itself, cut off where it repeats" do
          payload         = {body: "Café ☕".b}
          payload[:self]  = payload
          payload[:again] = payload

          appender.info("Looped", payload: payload)
          stored = appender.collection.find.first["payload"]

          assert_equal "Café ☕", stored["body"]
          assert_equal "#<Hash nested too deeply>", stored["self"]
          assert_equal "#<Hash nested too deeply>", stored["again"]
        end

        it "keeps the types of the other values of a deep entry" do
          nested = {body: "Café".b}
          40.times { nested = {a: nested} }
          at = Time.utc(2026, 11, 16)

          appender.info("Deep", payload: nested.merge(ratio: Float::NAN, max: Float::INFINITY, at: at))
          stored = appender.collection.find.first["payload"]

          assert_predicate stored["ratio"], :nan?
          assert_equal Float::INFINITY, stored["max"]
          assert_equal at, stored["at"]
        end

        # BSON reaches the deep binary body first, under :a, then refuses the object.
        it "leaves an object of a deep entry for BSON to refuse, without its JSON" do
          broken = Object.new
          def broken.to_json(*) = raise("not JSON")
          nested = {body: "Café".b}
          40.times { nested = {a: nested} }

          error = assert_raises(BSON::Error) { appender.info("Deep", payload: nested.merge(broken: broken)) }

          assert appender.message_error?(error)
        end

        # BSON refuses the binary body before it reaches the key.
        it "leaves a key that is a structure for BSON to refuse, without copying it" do
          key      = {}
          key[key] = 1

          error = assert_raises(BSON::Error) { appender.info("Keyed", payload: {body: "Café".b, key => 1}) }

          assert appender.message_error?(error)
        end

        it "stores text nested deeper than the JSON formatters write, cut off there" do
          nested = {body: "Café".b}
          40.times { nested = {a: nested} }

          appender.info("Deep", payload: nested)
          stored = appender.collection.find.first["payload"]
          30.times { stored = stored["a"] }

          assert_equal "#<Hash nested too deeply>", stored["a"]
        end

        it "does not copy a document that BSON accepts" do
          appender.stub(:storable, ->(_) { raise "copied" }) do
            appender.info("Café ☕", payload: {body: "Café ☕"})
          end

          assert_equal "Café ☕", appender.collection.find.first["message"]
        end
      end

      describe "#close" do
        it "closes the client, and a reopen connects it again" do
          appender.close

          assert_predicate appender.client, :closed?

          appender.reopen
          appender.info("after reopen")

          refute_predicate appender.client, :closed?
          assert_equal "after reopen", appender.collection.find.first["message"]
        end

        it "reports an error closing the client, rather than raising it" do
          appender.logger = SemanticLogger::Test::CaptureLogEvents.new
          appender.client.stub(:close, -> { raise Mongo::Error::OperationFailure, "closing" }) { appender.close }
          report = appender.logger.events.last

          assert_equal :warn, report.level
          assert_equal "Could not close the MongoDB client", report.message
          assert_equal "closing", report.exception.message
          appender.reopen
        end
      end

      describe "format logs into documents" do
        it "handle no arguments" do
          appender.debug
          document = appender.collection.find.first

          assert_equal :debug, document["level"]
          assert_nil document["message"]
          assert_equal thread_name, document["thread"]
          assert_kind_of Time, document["time"]
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
          assert_equal thread_name, document["thread"]
          assert_kind_of Time, document["time"]
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
          assert_equal thread_name, document["thread"]
          assert_kind_of Time, document["time"]
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
          assert_equal thread_name, document["thread"]
          assert_kind_of Time, document["time"]
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
            assert_equal thread_name, document["thread"]
            assert_kind_of Time, document["time"]
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
