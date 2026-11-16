require_relative "../test_helper"

module CoreExt
  class WarningTest < Minitest::Test
    # The warning as json 2.8.0 through 3.0.x print it, with the location Ruby adds.
    BINARY_WARNING = "common.rb:305: warning: JSON.generate: UTF-8 string passed as BINARY, " \
                     "this will raise an encoding error in json 3.0\n".freeze

    # Stand-in for `Warning`, so that the module can be tested on any json version. The module
    # prepended to it resolves `super` to the `warn` defined here.
    class WarningStub
      attr_reader :warnings

      def initialize
        @warnings = []
      end

      def warn(message, category: nil)
        @warnings << [message, category]
        nil
      end

      prepend SemanticLogger::CoreExt::Warning
    end

    # Stand-in for an application's own `Warning.warn`, which takes only the message.
    class MessageOnlyWarningStub
      attr_reader :warnings

      def initialize
        @warnings = []
      end

      def warn(message)
        @warnings << message
        nil
      end

      prepend SemanticLogger::CoreExt::Warning
    end

    describe SemanticLogger::CoreExt::Warning do
      let(:extension) { SemanticLogger::CoreExt::Warning }
      let(:warning) { WarningStub.new }

      before { Thread.current[extension::STATE] = nil }
      after { Thread.current[extension::STATE] = nil }

      describe "#warn" do
        it "drops json's warning about a binary String from serializing log data" do
          SemanticLogger::Utils.stub(:serializing_log_data?, true) { warning.warn(BINARY_WARNING) }

          assert_empty warning.warnings
          assert_nil Thread.current[extension::STATE]
        end

        it "notes that it dropped the warning while it is watched" do
          Thread.current[extension::STATE] = :watching
          SemanticLogger::Utils.stub(:serializing_log_data?, true) { warning.warn(BINARY_WARNING) }

          assert_equal :warned, Thread.current[extension::STATE]
        end

        it "passes on json's warning about a binary String from anywhere else" do
          SemanticLogger::Utils.stub(:serializing_log_data?, false) { warning.warn(BINARY_WARNING) }

          assert_equal [[BINARY_WARNING, nil]], warning.warnings
        end

        it "passes on any other warning, with its category" do
          SemanticLogger::Utils.stub(:serializing_log_data?, true) do
            warning.warn("lib/order.rb:12: warning: method redefined", category: :deprecated)
          end

          assert_equal [["lib/order.rb:12: warning: method redefined", :deprecated]], warning.warnings
        end

        it "passes a warning on without its category to a #warn that takes only the message" do
          warning = MessageOnlyWarningStub.new
          warning.warn("lib/order.rb:12: warning: method redefined", category: :deprecated)
          warning.warn("lib/order.rb:13: warning: assigned but unused variable")

          assert_equal ["lib/order.rb:12: warning: method redefined",
                        "lib/order.rb:13: warning: assigned but unused variable"],
                       warning.warnings
        end
      end

      describe ".unless_binary_string_warned" do
        it "returns the result of the block that serializes the log data" do
          result = extension.unless_binary_string_warned { "{}" }

          assert_equal "{}", result
          assert_nil Thread.current[extension::STATE]
        end
      end

      it "is prepended to Warning where the json gem warns about binary Strings" do
        ancestors = Warning.singleton_class.ancestors

        if extension::NEEDED
          assert_operator ancestors.index(extension), :<, ancestors.index(Warning.singleton_class)
        else
          refute_includes ancestors, extension
        end
      end

      # The json gem in the bundle decides whether these run: the latest json raises on a binary
      # String rather than warning.
      describe "with a json gem that warns about binary Strings" do
        before do
          skip "json #{JSON::VERSION} does not warn about binary Strings" unless extension::NEEDED
        end

        let(:binary) { "Café ☕".b }
        let(:appender) { SemanticLogger::Appender::IO.new(StringIO.new) }

        it "writes binary Strings anywhere in a log entry as UTF-8, without the warning" do
          log            = SemanticLogger::Log.new("WarningTest", :info)
          log.message    = "Received"
          log.payload    = {"clé".b => {body: binary, list: [binary]}}
          log.tags       = [binary]
          log.named_tags = {user: binary}
          log.exception  = RuntimeError.new(binary)

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

          line = nil
          _, err = capture_io { line = SemanticLogger::Formatters::Logfmt.new.call(log, appender) }

          assert_empty err
          assert_includes line, %(body="Café ☕")
        end

        it "writes a binary String under objects whose own #to_json serializes a Hash, however deep" do
          node = Struct.new(:child) { def to_json(*args) = {child: child}.to_json(*args) }
          tree = (1..40).reduce(binary) { |child, _| node.new(child) }

          json = nil
          _, err = capture_io { json = SemanticLogger::Utils.to_json(tree) }

          assert_empty err
          assert_includes json, %("Café ☕")
        end

        it "readies a UTF-8 copy for a writer that serializes it itself, such as GELF" do
          ready = nil
          _, err = capture_io { ready = SemanticLogger::Utils.json_ready({body: binary}) }

          assert_empty err
          assert_equal({body: "Café ☕"}, ready)
          assert_equal Encoding::UTF_8, ready[:body].encoding
          assert_nil Thread.current[extension::STATE]
        end

        it "readies a value without binary Strings as it is" do
          value = {body: "Café ☕"}

          assert_same value, SemanticLogger::Utils.json_ready(value)
        end

        it "still warns when the application serializes a binary String itself" do
          _, err = capture_io { JSON.generate([binary]) }

          assert_includes err, "UTF-8 string passed as BINARY"
        end

        it "still warns when an exception's own #message serializes a binary String" do
          body  = binary
          error = Class.new(StandardError) { define_method(:message) { "Rejected: #{JSON.generate(body: body)}" } }.new

          _, err = capture_io { SemanticLogger::Utils.exception_message(error) }

          assert_includes err, "UTF-8 string passed as BINARY"
        end
      end
    end
  end
end
