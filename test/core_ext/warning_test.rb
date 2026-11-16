require_relative "../test_helper"

module CoreExt
  class WarningTest < Minitest::Test
    # The warning as json 2.8.0 through 3.0.x print it, with the location Ruby adds.
    BINARY_WARNING = "common.rb:305: warning: JSON.generate: UTF-8 string passed as BINARY, " \
                     "this will raise an encoding error in json 3.0\n".freeze

    # Stand-in for `Warning`, so that the module can be tested on any json version. The extended
    # module's `super` resolves to the `warn` defined here.
    class WarningStub
      attr_reader :warnings

      def initialize
        @warnings = []
      end

      def warn(message, category: nil)
        @warnings << [message, category]
        nil
      end
    end

    # Records whether Semantic Logger is serializing log data when the json gem calls its #to_json.
    class SerializingProbe
      attr_reader :serializing

      def to_json(*)
        @serializing = SemanticLogger::CoreExt::Warning.serializing_log_data?
        "{}"
      end
    end

    describe SemanticLogger::CoreExt::Warning do
      let(:extension) { SemanticLogger::CoreExt::Warning }
      let(:warning) { WarningStub.new.extend(extension) }

      after do
        Thread.current[extension::STATE] = nil
      end

      describe "#warn" do
        it "drops json's warning about a binary String from serializing log data, and notes it" do
          extension.stub(:serializing_log_data?, true) { warning.warn(BINARY_WARNING) }

          assert_empty warning.warnings
          assert_equal :warned, Thread.current[extension::STATE]
        end

        it "passes on json's warning about a binary String from anywhere else" do
          extension.stub(:serializing_log_data?, false) { warning.warn(BINARY_WARNING) }

          assert_equal [[BINARY_WARNING, nil]], warning.warnings
          assert_nil Thread.current[extension::STATE]
        end

        it "passes on any other warning, with its category" do
          extension.stub(:serializing_log_data?, true) do
            warning.warn("lib/order.rb:12: warning: method redefined", category: :deprecated)
          end

          assert_equal [["lib/order.rb:12: warning: method redefined", :deprecated]], warning.warnings
        end
      end

      describe ".serializing_log_data?" do
        it "is true under a call in Utils" do
          probe = SerializingProbe.new
          SemanticLogger::Utils.to_json(probe)

          assert probe.serializing
        end

        it "is false anywhere else" do
          refute_predicate extension, :serializing_log_data?
        end
      end

      it "is extended into Warning where the json gem warns about binary Strings" do
        assert_equal extension::NEEDED, Warning.singleton_class.include?(extension)
      end

      # The json gem in the bundle decides whether these run: the latest json raises on a binary
      # String rather than warning.
      describe "with a json gem that warns about binary Strings" do
        before do
          skip "json #{JSON::VERSION} does not warn about binary Strings" unless extension::NEEDED
        end

        let(:binary) { "Café ☕".b }

        it "writes binary Strings anywhere in a log entry as UTF-8, without the warning" do
          log            = SemanticLogger::Log.new("WarningTest", :info)
          log.message    = "Received"
          log.payload    = {"clé".b => {body: binary, list: [binary]}}
          log.tags       = [binary]
          log.named_tags = {user: binary}
          log.exception  = RuntimeError.new(binary)
          appender       = SemanticLogger::Appender::IO.new(StringIO.new)

          json = nil
          _, err = capture_io { json = SemanticLogger::Formatters::Json.new.call(log, appender) }

          assert_empty err
          parsed = JSON.parse(json)

          assert_equal({"clé" => {"body" => "Café ☕", "list" => ["Café ☕"]}}, parsed["payload"])
          assert_equal ["Café ☕"], parsed["tags"]
          assert_equal({"user" => "Café ☕"}, parsed["named_tags"])
          assert_equal "Café ☕", parsed["exception"]["message"]
        end

        it "writes a binary String in :logfmt without the warning" do
          log         = SemanticLogger::Log.new("WarningTest", :info)
          log.message = "Received"
          log.payload = {body: binary}
          appender    = SemanticLogger::Appender::IO.new(StringIO.new)

          line = nil
          _, err = capture_io { line = SemanticLogger::Formatters::Logfmt.new.call(log, appender) }

          assert_empty err
          assert_includes line, %(body="Café ☕")
        end

        it "readies a UTF-8 copy for a writer that serializes it itself, such as GELF" do
          ready = nil
          _, err = capture_io { ready = SemanticLogger::Utils.json_ready({body: binary}) }

          assert_empty err
          assert_equal({body: "Café ☕"}, ready)
          assert_equal Encoding::UTF_8, ready[:body].encoding
        end

        it "readies a value without binary Strings as it is" do
          value = {body: "Café ☕"}

          assert_same value, SemanticLogger::Utils.json_ready(value)
        end

        it "still warns when the application serializes a binary String itself" do
          _, err = capture_io { JSON.generate([binary]) }

          assert_includes err, "UTF-8 string passed as BINARY"
        end
      end
    end
  end
end
