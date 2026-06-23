require_relative "../test_helper"
require "tempfile"

require "semantic_logger/core_ext/process"

module CoreExt
  class ProcessTest < Minitest::Test
    # Stand-in for `Process` that lets us drive `_fork`'s return value (the child
    # pid in the parent, 0 in the child) without performing a real fork. The
    # prepended module's `super` resolves to the `_fork` defined here.
    class ForkStub
      def initialize(fork_result)
        @fork_result = fork_result
      end

      def _fork
        @fork_result
      end

      def daemon(*)
        :daemonized
      end

      prepend SemanticLogger::CoreExt::Process
    end

    # Records that it was reopened by touching a marker file. Used by the real
    # fork test so the parent can observe what happened in the child.
    class ReopenRecorder < SemanticLogger::Test::CaptureLogEvents
      def initialize(marker)
        super()
        @marker = marker
      end

      def reopen
        File.write(@marker, "reopened")
      end
    end

    describe SemanticLogger::CoreExt::Process do
      describe "#_fork" do
        it "reopens in the child (super returns 0)" do
          calls = 0

          SemanticLogger.stub(:reopen, -> { calls += 1 }) do
            assert_equal 0, ForkStub.new(0)._fork
          end
          assert_equal 1, calls
        end

        it "does not reopen in the parent (super returns the child pid)" do
          calls = 0

          SemanticLogger.stub(:reopen, -> { calls += 1 }) do
            assert_equal 12_345, ForkStub.new(12_345)._fork
          end
          assert_equal 0, calls
        end

        it "does not reopen when reopen_on_fork is disabled" do
          calls                         = 0
          SemanticLogger.reopen_on_fork = false

          SemanticLogger.stub(:reopen, -> { calls += 1 }) do
            assert_equal 0, ForkStub.new(0)._fork
          end
          assert_equal 0, calls
        ensure
          SemanticLogger.reopen_on_fork = nil
        end
      end

      describe "#daemon" do
        it "reopens and returns the result of super" do
          calls = 0

          SemanticLogger.stub(:reopen, -> { calls += 1 }) do
            assert_equal :daemonized, ForkStub.new(0).daemon
          end
          assert_equal 1, calls
        end
      end
    end

    describe "SemanticLogger.reopen_on_fork?" do
      it "is enabled by default" do
        assert_predicate SemanticLogger, :reopen_on_fork?
      end

      it "can be disabled" do
        SemanticLogger.reopen_on_fork = false

        refute_predicate SemanticLogger, :reopen_on_fork?
      ensure
        SemanticLogger.reopen_on_fork = nil
      end
    end

    describe "SemanticLogger.reopen" do
      it "reopens once per process and no-ops on a repeat call" do
        calls = 0
        SemanticLogger.instance_variable_set(:@reopened_pid, nil)

        SemanticLogger::Logger.processor.stub(:reopen, -> { calls += 1 }) do
          SemanticLogger.reopen
          SemanticLogger.reopen
        end

        assert_equal 1, calls
      end

      it "reopens again when forced" do
        calls = 0
        SemanticLogger.instance_variable_set(:@reopened_pid, nil)

        SemanticLogger::Logger.processor.stub(:reopen, -> { calls += 1 }) do
          SemanticLogger.reopen
          SemanticLogger.reopen(force: true)
        end

        assert_equal 2, calls
      end
    end

    describe "automatic reopen after a real fork" do
      it "reopens appenders in the child" do
        skip "fork not supported on this platform" unless Process.respond_to?(:fork) && Process.respond_to?(:_fork)

        marker = Tempfile.new("reopen_on_fork").path
        File.delete(marker)

        appender = SemanticLogger.add_appender(appender: ReopenRecorder.new(marker))
        begin
          pid = Process.fork do
            # The _fork hook should have already reopened appenders in this child.
            exit!(0)
          end
          Process.wait(pid)

          assert_path_exists marker, "expected the appender to be reopened in the child"
        ensure
          SemanticLogger.remove_appender(appender)
          FileUtils.rm_f(marker)
        end
      end
    end
  end
end
