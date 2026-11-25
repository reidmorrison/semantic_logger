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
        assert Ractor.shareable?(CallSite.const_get(:DISPATCH_LABELS))
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

      it "shares the constants read while reporting a deprecation" do
        %i[LIB_DIR LIB_FILE PREFIX WARNING RUBY_PATHS RUBY_LIB_DIRS].each do |name|
          assert Ractor.shareable?(Deprecation.const_get(name)), "#{name} is not shareable"
        end
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

        it "goes back to this machine's host name when the host is set to nil, and shares it" do
          original = SemanticLogger.host
          SemanticLogger.host = nil

          assert_equal Socket.gethostname, SemanticLogger.host
          assert Ractor.shareable?(SemanticLogger.host)
        ensure
          SemanticLogger.host = original
        end
      end

      it "shares the call site skip paths" do
        SemanticLogger.call_site_skip_paths = [+"app/lib/audit_log.rb"]

        assert Ractor.shareable?(SemanticLogger.call_site_skip_paths)
      ensure
        SemanticLogger.call_site_skip_paths = nil
      end

      it "shares a call site" do
        assert Ractor.shareable?(CallSite.capture)
        assert Ractor.shareable?(CallSite.parse(+"/app/order.rb:42:in 'Order#submit'"))
      end

      it "returns a value that cannot be copied as it is" do
        assert_same Thread.current, Utils.make_shareable(Thread.current, copy: true)
      end

      it "shares the paths stripped from backtraces, without freezing RubyGems' own Strings" do
        Utils.instance_variable_set(:@strip_paths, nil)

        assert Ractor.shareable?(Utils.strip_paths)
        refute_predicate RbConfig::CONFIG["rubylibdir"], :frozen?
      end

      it "reads the default host name in a Ractor" do
        skip "Logging from a Ractor requires Ruby 4.0" unless ruby4?

        original = SemanticLogger.host
        begin
          SemanticLogger.host = nil
          found               = in_ractor { SemanticLogger.host }
        ensure
          SemanticLogger.host = original
        end

        assert_equal original, found
      end

      it "builds a log entry inside a Ractor" do
        skip "Logging from a Ractor requires Ruby 4.0" unless ruby4?

        payload, call_site, application = in_ractor do
          log = SemanticLogger::Log.new("InRactor", :error)
          log.assign(**log.extract_arguments({user: "jack", duration: 12.5}, "Failed"))
          [log.payload, log.call_site, SemanticLogger.application]
        end

        assert_equal({user: "jack"}, payload)
        assert_equal __FILE__, call_site.path
        assert_equal SemanticLogger.application, application
      end

      it "records a Thread::Backtrace::Location supplied inside a Ractor as a call site" do
        skip "Logging from a Ractor requires Ruby 4.0" unless ruby4?

        begin
          SemanticLogger.call_site_level = :info
          call_site = in_ractor do
            log = SemanticLogger::Log.new("InRactor", :info)
            log.assign(message: "Hello", call_site: caller_locations(0, 1).first)
            log.call_site
          end
        ensure
          SemanticLogger.call_site_level = :error
        end

        assert_equal __FILE__, call_site.path
        assert Ractor.shareable?(call_site)
      end

      it "records a call site inside a Ractor, with skip paths" do
        skip "Logging from a Ractor requires Ruby 4.0" unless ruby4?

        begin
          SemanticLogger.call_site_level      = :info
          SemanticLogger.call_site_skip_paths = ["app/lib/audit_log.rb"]
          call_site = in_ractor do
            log = SemanticLogger::Log.new("InRactor", :info)
            log.assign(message: "Hello")
            log.call_site
          end
        ensure
          SemanticLogger.call_site_level      = :error
          SemanticLogger.call_site_skip_paths = nil
        end

        assert_equal __FILE__, call_site.path
      end
    end
  end
end
