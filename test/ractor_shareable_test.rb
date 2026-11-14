require_relative "test_helper"

module SemanticLogger
  # The constants and settings that code running in a Ractor reads while logging must be shareable.
  class RactorShareableTest < Minitest::Test
    describe "Ractor shareable state" do
      before do
        skip "This Ruby has no Ractors" unless defined?(::Ractor)
      end

      # Ruby 4.0 can share an UnboundMethod, and has Ractor#value.
      def ruby4?
        defined?(::Ractor::Port)
      end

      # Runs the block in a new Ractor, without Ruby's warning that Ractors are experimental.
      def in_ractor(*args, &block)
        experimental           = Warning[:experimental]
        Warning[:experimental] = false
        ::Ractor.new(*args, &block).value
      ensure
        Warning[:experimental] = experimental
      end

      it "shares the constants read while building a log entry" do
        assert Ractor.shareable?(Log.const_get(:ARGUMENT_VALIDATORS))
        assert Ractor.shareable?(Log.const_get(:REAL_NUMBER))
        assert Ractor.shareable?(Utils.extract_paths)
        assert Ractor.shareable?(Levels::MAPPED_LEVELS)
      end

      it "shares the UnboundMethod constants on Ruby 4.0" do
        skip "Ruby #{RUBY_VERSION} cannot share an UnboundMethod" unless ruby4?

        assert Ractor.shareable?(Log.const_get(:HASH_KEY))
        assert Ractor.shareable?(ExceptionDetails.const_get(:DETAILED_MESSAGE))
      end

      it "shares the formatter constants" do
        assert Ractor.shareable?(Formatters::Base::CONTROL_CHAR_ESCAPES)
        assert Ractor.shareable?(Formatters::Logfmt.const_get(:EXCEPTION_FIELDS))
      end

      describe "settings" do
        %i[host application environment].each do |setting|
          it "stores a shareable copy of the #{setting}, leaving the value supplied as it is" do
            original = SemanticLogger.public_send(setting)
            value    = "some #{setting}"
            SemanticLogger.public_send(:"#{setting}=", value)

            assert_equal "some #{setting}", SemanticLogger.public_send(setting)
            assert Ractor.shareable?(SemanticLogger.public_send(setting))
            refute_predicate value, :frozen?
          ensure
            SemanticLogger.public_send(:"#{setting}=", original)
          end
        end

        it "shares the host name found by default" do
          original = SemanticLogger.host
          SemanticLogger.host = nil

          assert Ractor.shareable?(SemanticLogger.host)
        ensure
          SemanticLogger.host = original
        end
      end

      it "builds a log entry inside a Ractor" do
        skip "Logging from a Ractor requires Ruby 4.0" unless ruby4?

        payload, backtrace, application = in_ractor do
          log = SemanticLogger::Log.new("InRactor", :error)
          log.assign(**log.extract_arguments({user: "jack", duration: 12.5}, "Failed"))
          [log.payload, log.backtrace, SemanticLogger.application]
        end

        assert_equal({user: "jack"}, payload)
        refute_empty backtrace
        assert_equal SemanticLogger.application, application
      end
    end
  end
end
