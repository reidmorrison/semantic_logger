require_relative "test_helper"
require_relative "signal_trap_helper"

module SemanticLogger
  class CallSiteTest < Minitest::Test
    # Methods defined in files named like Semantic Logger itself, Ruby's own methods, and an
    # application's logging helper, so that the frames between the test and CallSite.capture have the
    # paths that it checks.
    module Frames
      # rubocop:disable Style/EvalWithLocation -- each frame needs the path of the code it stands in for
      module_eval(<<~RUBY, "/gems/semantic_logger/lib/semantic_logger/fake.rb", 1)
        # Captures the call site this many frames deep in Semantic Logger.
        def self.capture(depth = 0)
          depth.zero? ? SemanticLogger::CallSite.capture : capture(depth - 1)
        end
      RUBY

      module_eval(<<~RUBY, "<internal:fake>", 1)
        def self.ruby_internal
          capture
        end
      RUBY

      module_eval(<<~RUBY, "/app/lib/audit_log.rb", 1)
        def self.helper
          capture
        end

        def self.log_helper(logger)
          logger.info("Audit")
        end
      RUBY
      # rubocop:enable Style/EvalWithLocation
    end

    # Logs from a named method, so that the call site has a label to check.
    class Order
      include SemanticLogger::Loggable

      def submit
        logger.info("Submitted")
        __LINE__ - 1
      end

      def self.find_open
        logger.info("Finding")
        __LINE__ - 1
      end

      def measured
        logger.measure_info("Measured") { 1 }
        __LINE__ - 1
      end

      def with_block
        logger.info { "From a block" }
        __LINE__ - 1
      end

      def in_each
        [1].each { logger.info("In each") }
        __LINE__ - 1
      end

      def via_public_send(level = :info)
        logger.public_send(level, "Dispatched")
        __LINE__ - 1
      end

      def via_method_call
        logger.method(:info).call("Dispatched")
        __LINE__ - 1
      end

      def via_bind_call
        SemanticLogger::Logger.instance_method(:info).bind_call(logger, "Dispatched")
        __LINE__ - 1
      end

      def via_public_send_in_block(level = :info)
        [1].each { logger.public_send(level, "Dispatched") }
        __LINE__ - 1
      end
    end

    # Shared by the describe blocks, which do not inherit this class's methods.
    module Helpers
      # Ruby 3.4 added the class to a frame's label, but JRuby, which is Ruby 3.4 compatible, did not.
      def label_for(klass, method)
        if RUBY_ENGINE == "ruby" && RUBY_VERSION >= "3.4"
          "#{klass}#{method}"
        else
          method.delete_prefix("#").delete_prefix(".")
        end
      end

      def with_call_site_level(level)
        original = SemanticLogger.call_site_level
        SemanticLogger.call_site_level = level
        yield
      ensure
        SemanticLogger.call_site_level = original
      end

      def with_backtrace_level(level)
        original = SemanticLogger.backtrace_level
        SemanticLogger.backtrace_level = level
        yield
      ensure
        SemanticLogger.backtrace_level = original
      end

      def with_skip_paths(paths)
        original = SemanticLogger.call_site_skip_paths
        SemanticLogger.call_site_skip_paths = paths
        yield
      ensure
        SemanticLogger.call_site_skip_paths = original
      end
    end

    describe CallSite do
      include Helpers

      describe ".capture" do
        it "returns the frame that called it" do
          call_site = CallSite.capture
          line      = __LINE__ - 1

          assert_equal __FILE__, call_site.path
          assert_equal line, call_site.line
          assert_includes call_site.label, "block"
        end

        it "skips Semantic Logger's own frames, however many there are" do
          call_site = Frames.capture(20)
          line      = __LINE__ - 1

          assert_equal __FILE__, call_site.path
          assert_equal line, call_site.line
        end

        it "skips the frames of Ruby's own methods" do
          call_site = Frames.ruby_internal
          line      = __LINE__ - 1

          assert_equal __FILE__, call_site.path
          assert_equal line, call_site.line
        end

        it "returns the frame of a logging helper" do
          call_site = Frames.helper

          assert_equal "/app/lib/audit_log.rb", call_site.path
          assert_equal 2, call_site.line
        end

        it "skips the frames of call_site_skip_paths" do
          with_skip_paths(["app/lib/audit_log.rb"]) do
            call_site = Frames.helper
            line      = __LINE__ - 1

            assert_equal __FILE__, call_site.path
            assert_equal line, call_site.line
          end
        end

        it "returns nil when every frame is skipped" do
          # New skip paths start a new cache, so that the stub decides every path.
          with_skip_paths(["/not/a/path/"]) do
            Utils.stub(:extract_path?, true) do
              assert_nil CallSite.capture
            end
          end
        end

        it "remembers whether each path is skipped until the skip paths change" do
          assert_equal __FILE__, CallSite.capture.path

          Utils.stub(:extract_path?, true) do
            assert_equal __FILE__, CallSite.capture.path
          end

          with_skip_paths([File.basename(__FILE__)]) do
            refute_equal __FILE__, CallSite.capture&.path
          end
        end

        describe "in a signal trap, where adding to the cache would lock a Mutex" do
          include SignalTrapHelper

          it "returns the frame that called it, without remembering whether its path is skipped" do
            # New skip paths start a new cache.
            with_skip_paths(["/not/a/path/in/a/trap/"]) do
              call_site = in_signal_trap { Frames.helper }

              assert_kind_of CallSite, call_site
              assert_equal "/app/lib/audit_log.rb", call_site.path
              cache = CallSite.send(:skip_cache, SemanticLogger.call_site_skip_paths)

              assert_empty cache.keys
              Frames.helper

              refute_empty cache.keys
            end
          end
        end

        it "returns a frozen call site of frozen Strings" do
          call_site = CallSite.capture

          assert_predicate call_site, :frozen?
          assert_predicate call_site.path, :frozen?
          assert_predicate call_site.label, :frozen?
        end
      end

      describe ".locate" do
        it "returns the first line of a supplied backtrace" do
          call_site = CallSite.locate(backtrace: ["/app/models/order.rb:42:in 'Order#submit'", "/app/b.rb:1"])

          assert_equal CallSite.new(path: "/app/models/order.rb", line: 42, label: "Order#submit"), call_site
        end

        it "captures the call site without a supplied backtrace" do
          call_site = CallSite.locate
          line      = __LINE__ - 1

          assert_equal __FILE__, call_site.path
          assert_equal line, call_site.line
        end

        it "captures the call site for an empty supplied backtrace" do
          call_site = CallSite.locate(backtrace: [])

          assert_equal __FILE__, call_site.path
        end
      end

      describe ".from" do
        it "returns a CallSite of frozen Strings as it is" do
          call_site = CallSite.new(path: "/app/a.rb".freeze, line: 1, label: nil)

          assert_same call_site, CallSite.from(call_site)
        end

        it "makes a frozen String of a String subclass, leaving it as it is" do
          subclass  = Class.new(String)
          path      = subclass.new("/app/a.rb")
          call_site = CallSite.from(CallSite.new(path: path, line: 1, label: subclass.new("x")))

          assert_instance_of String, call_site.path
          assert_instance_of String, call_site.label
          assert_predicate call_site.path, :frozen?
          refute_predicate path, :frozen?
        end

        it "makes frozen copies of the Strings of a supplied CallSite" do
          path      = +"/app/a.rb"
          call_site = CallSite.from(CallSite.new(path: path, line: 1, label: +"x"))

          assert_predicate call_site.path, :frozen?
          assert_predicate call_site.label, :frozen?
          refute_predicate path, :frozen?
        end

        it "makes a frozen call site from a Thread::Backtrace::Location" do
          location  = caller_locations(0, 1).first
          call_site = CallSite.from(location)

          assert_equal [location.path, location.lineno, location.label],
                       [call_site.path, call_site.line, call_site.label]
          assert_predicate call_site.label, :frozen?
        end
      end

      describe ".supplied?" do
        it "accepts false, a CallSite, or a Thread::Backtrace::Location" do
          assert CallSite.supplied?(false)
          assert CallSite.supplied?(CallSite.new(path: "/app/a.rb", line: 1, label: nil))
          assert CallSite.supplied?(caller_locations(0, 1).first)
        end

        it "rejects the values parsed data can hold, other than false" do
          [nil, true, "/app/a.rb:1", ["/app/a.rb:1"], {path: "/app/a.rb"}, 1].each do |value|
            refute CallSite.supplied?(value), value.inspect
          end
        end

        it "rejects a CallSite without a String path and an Integer line" do
          refute CallSite.supplied?(CallSite.new(path: nil, line: "x", label: 3))
          refute CallSite.supplied?(CallSite.new(path: "/app/a.rb", line: 1, label: 3))
        end

        it "calls no method of a CallSite's values" do
          lying = BasicObject.new
          def lying.is_a?(_klass) = true

          refute CallSite.supplied?(CallSite.new(path: BasicObject.new, line: 1, label: nil))
          refute CallSite.supplied?(CallSite.new(path: "/app/a.rb", line: 1, label: BasicObject.new))
          refute CallSite.supplied?(CallSite.new(path: lying, line: 1, label: nil))
        end

        it "calls no method of the value" do
          value = BasicObject.new
          def value.==(_other) = raise(TypeError, "compared")

          refute CallSite.supplied?(value)
        end
      end

      describe ".parse" do
        it "parses a backtrace line as Ruby 3.4 and later write it" do
          call_site = CallSite.parse("/app/models/order.rb:42:in 'Order#submit'")

          assert_equal CallSite.new(path: "/app/models/order.rb", line: 42, label: "Order#submit"), call_site
        end

        it "parses a backtrace line as Ruby 3.3 and earlier write it" do
          call_site = CallSite.parse("/app/models/order.rb:42:in `submit'")

          assert_equal CallSite.new(path: "/app/models/order.rb", line: 42, label: "submit"), call_site
        end

        it "parses a line without a label" do
          assert_equal CallSite.new(path: "/app/models/order.rb", line: 42, label: nil),
                       CallSite.parse("/app/models/order.rb:42")
        end

        it "parses a Windows path" do
          call_site = CallSite.parse("C:/app/order.rb:42:in 'Order#submit'")

          assert_equal "C:/app/order.rb", call_site.path
          assert_equal 42, call_site.line
        end

        it "returns nil for a line with a line break, which only a forged line has" do
          assert_nil CallSite.parse("forged\n/app/order.rb:42:in 'Order#submit'")
          assert_nil CallSite.parse("/app/order.rb:42:in 'Order#submit'\nforged")&.label
        end

        it "parses the path of code evaluated at runtime, which holds a line number of its own" do
          assert_equal CallSite.new(path: "(eval at /app/a.rb:3)", line: 1, label: "<main>"),
                       CallSite.parse("(eval at /app/a.rb:3):1:in '<main>'")
        end

        it "parses a long forged line, at the first line number followed by a label" do
          call_site = CallSite.parse("#{"a:1:in 'x" * 20_000}'")

          assert_equal "a", call_site.path
          assert_equal 1, call_site.line
          assert_equal 180_000 - 8, call_site.label.size
        end

        it "returns nil for a line that is not valid text" do
          assert_nil CallSite.parse("/app/caf\xE9.rb:1:in 'x'")
          assert_nil CallSite.parse("/app/order.rb:1:in 'x'".encode(Encoding::UTF_16LE))
        end

        it "parses a line in another ASCII compatible encoding" do
          assert_equal 1, CallSite.parse("/app/order.rb:1:in 'x'".b).line
        end

        it "returns nil for a line number of more than 10 digits" do
          assert_nil CallSite.parse("/app/order.rb:#{'9' * 11}:in 'x'")
          assert_nil CallSite.parse("/app/order.rb:#{'9' * 11}")
          assert_equal 9_999_999_999, CallSite.parse("/app/order.rb:#{'9' * 10}:in 'x'").line
        end

        it "leaves out the label of a line that ends with its opening quote" do
          assert_equal CallSite.new(path: "/app/order.rb", line: 12, label: nil),
                       CallSite.parse("/app/order.rb:12:in '")
        end

        it "returns nil for a line without a path" do
          assert_nil CallSite.parse(":12:in 'x'")
          assert_nil CallSite.parse(":12")
        end

        it "returns nil for a line without a line number, or a value that is not a String" do
          assert_nil CallSite.parse("not a backtrace line")
          assert_nil CallSite.parse(nil)
          assert_nil CallSite.parse(42)
        end

        it "returns frozen Strings" do
          call_site = CallSite.parse(+"/app/models/order.rb:42:in 'Order#submit'")

          assert_predicate call_site.path, :frozen?
          assert_predicate call_site.label, :frozen?
        end
      end

      describe "#file_name_and_line" do
        let(:call_site) { CallSite.new(path: "/app/models/order.rb", line: 42, label: "Order#submit") }

        it "returns the path and line" do
          assert_equal ["/app/models/order.rb", 42], call_site.file_name_and_line
        end

        it "returns the file name without its directory, with short_name" do
          assert_equal ["order.rb", 42], call_site.file_name_and_line(short_name: true)
        end
      end

      describe "#to_s" do
        it "writes the call site as a backtrace line" do
          assert_equal "/app/models/order.rb:42:in 'Order#submit'",
                       CallSite.new(path: "/app/models/order.rb", line: 42, label: "Order#submit").to_s
        end

        it "leaves out a missing label" do
          assert_equal "/app/models/order.rb:42", CallSite.new(path: "/app/models/order.rb", line: 42, label: nil).to_s
        end
      end
    end

    describe "logging" do
      include Helpers

      it "records no call site below :error by default" do
        assert_equal :error, SemanticLogger.call_site_level

        events = semantic_logger_events { Order.new.submit }

        assert_nil events.first.call_site
      end

      it "records where an instance method logged" do
        with_call_site_level(:info) do
          line   = nil
          events = semantic_logger_events { line = Order.new.submit }

          assert_equal CallSite.new(path: __FILE__, line: line, label: label_for(Order, "#submit")),
                       events.first.call_site
        end
      end

      it "records where a class method logged" do
        with_call_site_level(:info) do
          line   = nil
          events = semantic_logger_events { line = Order.find_open }

          assert_equal CallSite.new(path: __FILE__, line: line, label: label_for(Order, ".find_open")),
                       events.first.call_site
        end
      end

      it "records where a measure call logged" do
        with_call_site_level(:info) do
          line   = nil
          events = semantic_logger_events { line = Order.new.measured }

          assert_equal line, events.first.call_site.line
          assert_equal label_for(Order, "#measured"), events.first.call_site.label
        end
      end

      it "records where a log call with a block logged" do
        with_call_site_level(:info) do
          line   = nil
          events = semantic_logger_events { line = Order.new.with_block }

          assert_equal line, events.first.call_site.line
          assert_equal label_for(Order, "#with_block"), events.first.call_site.label
        end
      end

      it "records the block, not Array#each, for a log call in a block" do
        with_call_site_level(:info) do
          line   = nil
          events = semantic_logger_events { line = Order.new.in_each }

          assert_equal line, events.first.call_site.line
          assert_equal "block in #{label_for(Order, '#in_each')}", events.first.call_site.label
        end
      end

      %i[via_public_send via_method_call via_bind_call].each do |method|
        it "records the method that called the logger through #{method.to_s.delete_prefix('via_')}" do
          with_call_site_level(:info) do
            line   = nil
            events = semantic_logger_events { line = Order.new.public_send(method) }

            assert_equal CallSite.new(path: __FILE__, line: line, label: label_for(Order, "##{method}")),
                         events.first.call_site
          end
        end
      end

      it "records the block that called the logger through public_send" do
        with_call_site_level(:info) do
          line   = nil
          events = semantic_logger_events { line = Order.new.via_public_send_in_block }

          assert_equal line, events.first.call_site.line
          assert_equal "block in #{label_for(Order, '#via_public_send_in_block')}", events.first.call_site.label
        end
      end

      it "records an application's own call method that the next frame called on the same line" do
        skip "Only CRuby 3.4 and later can tell Method#call from a method named call" unless
          RUBY_ENGINE == "ruby" && RUBY_VERSION >= "3.4"

        with_call_site_level(:info) do
          # Both methods on one line, so that the frame of outer is at the same path and line as call's.
          handler = Class.new { def call(logger) = logger.info("Handled"); def outer(logger) = call(logger) }.new # rubocop:disable Style/Semicolon
          line    = __LINE__ - 1
          events  = semantic_logger_events { handler.outer(SemanticLogger["Handler"]) }

          assert_equal line, events.first.call_site.line
          assert_equal "call", events.first.call_site.label
        end
      end

      it "logs a supplied backtrace that is not valid text, without a call site" do
        with_call_site_level(:info) do
          events = semantic_logger_events { SemanticLogger["Order"].info("x", backtrace: ["/app/caf\xE9.rb:1"]) }

          assert_nil events.first.call_site
        end
      end

      describe "a call site that the log call supplies" do
        let(:supplied) { CallSite.new(path: "/app/views/orders/index.html.erb", line: 1, label: nil) }

        it "records a supplied CallSite" do
          with_call_site_level(:info) do
            events = semantic_logger_events { SemanticLogger["Order"].info("Rendered", call_site: supplied) }

            assert_equal supplied, events.first.call_site
          end
        end

        it "records a supplied Thread::Backtrace::Location" do
          with_call_site_level(:info) do
            location = caller_locations(0, 1).first
            events   = semantic_logger_events { SemanticLogger["Order"].info("Query", call_site: location) }

            assert_equal CallSite.new(path: location.path, line: location.lineno, label: location.label),
                         events.first.call_site
          end
        end

        it "records no call site for call_site: false" do
          with_call_site_level(:info) do
            events = semantic_logger_events { SemanticLogger["Rack"].info("Started", call_site: false) }

            assert_nil events.first.call_site
            assert_nil events.first.payload
          end
        end

        it "does not read the stack for call_site: false" do
          with_call_site_level(:info) do
            CallSite.stub(:capture, -> { raise "read the stack" }) do
              events = semantic_logger_events { SemanticLogger["Rack"].info("Started", call_site: false) }

              assert_nil events.first.call_site
            end
          end
        end

        it "accepts it with the message in the Hash" do
          with_call_site_level(:info) do
            events = semantic_logger_events { SemanticLogger["Rack"].info(message: "Started", call_site: false) }

            assert_nil events.first.call_site
            assert_equal "Started", events.first.message
          end
        end

        it "prefers it to a supplied backtrace" do
          with_call_site_level(:info) do
            events = semantic_logger_events do
              SemanticLogger["Order"].info("Query", call_site: supplied, backtrace: ["/app/other.rb:1:in 'x'"])
            end

            assert_equal supplied, events.first.call_site
            assert_equal ["/app/other.rb:1:in 'x'"], events.first.backtrace
          end
        end

        it "records it below call_site_level" do
          with_call_site_level(:warn) do
            events = semantic_logger_events { SemanticLogger["Order"].info("Rendered", call_site: supplied) }

            assert_equal supplied, events.first.call_site
            assert_nil events.first.payload
          end
        end

        it "records it without call_site_level" do
          with_call_site_level(nil) do
            events = semantic_logger_events { SemanticLogger["Order"].info("Rendered", call_site: supplied) }

            assert_equal supplied, events.first.call_site
          end
        end

        it "records a supplied Thread::Backtrace::Location below call_site_level" do
          with_call_site_level(:warn) do
            location = caller_locations(0, 1).first
            events   = semantic_logger_events { SemanticLogger["Order"].info("Query", call_site: location) }

            assert_equal location.lineno, events.first.call_site.line
          end
        end

        it "records no call site for call_site: false below call_site_level" do
          with_call_site_level(:warn) do
            events = semantic_logger_events { SemanticLogger["Rack"].info("Started", call_site: false) }

            assert_nil events.first.call_site
            assert_nil events.first.payload
          end
        end

        it "does not take one from a supplied backtrace below call_site_level" do
          with_call_site_level(:warn) do
            events = semantic_logger_events { SemanticLogger["Order"].info("Query", backtrace: ["/app/a.rb:1:in 'x'"]) }

            assert_nil events.first.call_site
            assert_equal ["/app/a.rb:1:in 'x'"], events.first.backtrace
          end
        end

        it "records it as a measure option below call_site_level" do
          with_call_site_level(:warn) do
            events = semantic_logger_events do
              SemanticLogger["View"].measure_info("Rendered", call_site: supplied) { 1 }
            end

            assert_equal supplied, events.first.call_site
          end
        end

        it "keeps a value that parsed data can hold in the payload, and reads the stack" do
          with_call_site_level(:info) do
            forged = {call_site: "/app/forged.rb:1:in 'x'"}
            events = semantic_logger_events { SemanticLogger["Order"].info("Webhook", forged) }
            line   = __LINE__ - 1

            assert_equal({call_site: "/app/forged.rb:1:in 'x'"}, events.first.payload)
            assert_equal line, events.first.call_site.line
          end
        end

        it "keeps a malformed CallSite in the payload, and reads the stack" do
          with_call_site_level(:info) do
            malformed = CallSite.new(path: nil, line: "x", label: nil)
            events    = semantic_logger_events { SemanticLogger["Order"].info("Webhook", call_site: malformed) }
            line      = __LINE__ - 1

            assert_equal({call_site: malformed}, events.first.payload)
            assert_equal line, events.first.call_site.line
          end
        end

        it "keeps a value whose == raises in the payload" do
          with_call_site_level(:info) do
            value = Object.new
            def value.==(_other) = raise(TypeError, "compared")
            events = semantic_logger_events { SemanticLogger["Order"].info("Webhook", call_site: value) }

            assert_same value, events.first.payload[:call_site]
          end
        end

        it "accepts it as a measure option" do
          with_call_site_level(:info) do
            events = semantic_logger_events do
              SemanticLogger["View"].measure_info("Rendered", call_site: supplied) { 1 }
              SemanticLogger["View"].measure_info("Rendered", call_site: false) { 1 }
            end

            assert_equal supplied, events[0].call_site
            assert_nil events[1].call_site
          end
        end

        it "still takes the file name and line from a captured backtrace for call_site: false" do
          with_call_site_level(:info) do
            events = semantic_logger_events { SemanticLogger["Rack"].error("Failed", call_site: false) }
            line   = __LINE__ - 1

            assert_nil events.first.call_site
            assert_equal [File.basename(__FILE__), line], events.first.file_name_and_line(true)
          end
        end

        it "keeps a call site returned by a logging block in the payload" do
          with_call_site_level(:info) do
            events = semantic_logger_events { SemanticLogger["Order"].info("Hello") { {call_site: false} } }
            line   = __LINE__ - 1

            assert_equal({call_site: false}, events.first.payload)
            assert_equal line, events.first.call_site.line
          end
        end
      end

      it "records the first line of a backtrace that the log call supplies" do
        with_call_site_level(:info) do
          backtrace = ["/app/models/order.rb:42:in 'Order#submit'", "/app/controllers/orders.rb:7:in 'create'"]
          events    = semantic_logger_events { SemanticLogger["Order"].info("Query", backtrace: backtrace) }

          assert_equal CallSite.new(path: "/app/models/order.rb", line: 42, label: "Order#submit"),
                       events.first.call_site
        end
      end

      it "records the call site only at or above call_site_level" do
        with_call_site_level(:warn) do
          events = semantic_logger_events do
            SemanticLogger["Order"].info("Below")
            SemanticLogger["Order"].warn("At")
            SemanticLogger["Order"].error("Above")
          end

          assert_nil events[0].call_site
          refute_nil events[1].call_site
          refute_nil events[2].call_site
        end
      end

      it "records the call site at the level an exception changes the entry to" do
        with_call_site_level(:error) do
          events = semantic_logger_events do
            SemanticLogger["Order"].measure_info("Failed", on_exception_level: :error) { raise "Oh no" }
          rescue RuntimeError
            nil
          end

          assert_equal :error, events.first.level
          refute_nil events.first.call_site
        end
      end

      it "keeps the call site when a logging block returns a backtrace" do
        with_call_site_level(:info) do
          with_backtrace_level(nil) do
            events = semantic_logger_events do
              SemanticLogger["Order"].info("Hello") { {backtrace: ["/app/forged.rb:1:in 'forged'"]} }
            end
            line = __LINE__ - 2

            assert_equal ["/app/forged.rb:1:in 'forged'"], events.first.backtrace
            assert_equal __FILE__, events.first.call_site.path
            assert_equal line, events.first.call_site.line
          end
        end
      end

      it "records where a logging helper logged, or the code that called it when its path is skipped" do
        with_call_site_level(:info) do
          events = semantic_logger_events { Frames.log_helper(SemanticLogger["Order"]) }

          assert_equal "/app/lib/audit_log.rb", events.first.call_site.path

          with_skip_paths(["app/lib/audit_log.rb"]) do
            events = semantic_logger_events { Frames.log_helper(SemanticLogger["Order"]) }
            line   = __LINE__ - 1

            assert_equal __FILE__, events.first.call_site.path
            assert_equal line, events.first.call_site.line
          end
        end
      end
    end
  end
end
