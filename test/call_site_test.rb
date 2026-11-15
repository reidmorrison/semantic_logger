require_relative "test_helper"

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
    end

    # Shared by the describe blocks, which do not inherit this class's methods.
    module Helpers
      # Ruby 3.4 added the class to a frame's label.
      def label_for(klass, method)
        RUBY_VERSION >= "3.4" ? "#{klass}#{method}" : method.delete_prefix("#").delete_prefix(".")
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

        it "returns a frozen call site of frozen Strings" do
          call_site = CallSite.capture

          assert_predicate call_site, :frozen?
          assert_predicate call_site.path, :frozen?
          assert_predicate call_site.label, :frozen?
        end
      end

      describe ".locate" do
        it "returns the first line of a supplied backtrace" do
          call_site = CallSite.locate(["/app/models/order.rb:42:in 'Order#submit'", "/app/b.rb:1"])

          assert_equal CallSite.new(path: "/app/models/order.rb", line: 42, label: "Order#submit"), call_site
        end

        it "captures the call site without a supplied backtrace" do
          call_site = CallSite.locate
          line      = __LINE__ - 1

          assert_equal __FILE__, call_site.path
          assert_equal line, call_site.line
        end

        it "returns nil for an empty supplied backtrace" do
          assert_nil CallSite.locate([])
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

      it "records no call site by default" do
        assert_nil SemanticLogger.call_site_level

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
