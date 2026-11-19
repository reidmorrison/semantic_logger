require_relative "../test_helper"

class RequestTest < Minitest::Test
  describe SemanticLogger::QueueProcessor::Request do
    let(:request) { SemanticLogger::QueueProcessor::Request.new(:flush) }
    let(:finished_thread) { Thread.new { nil }.tap(&:join) }

    it "knows its command" do
      assert_equal :flush, request.command
    end

    it "replies true once the block has run" do
      request.reply { nil }

      assert(request.wait { finished_thread.alive? })
    end

    it "replies false when the block raises, and lets the error propagate" do
      assert_raises(RuntimeError) { request.reply { raise "boom" } }
      refute(request.wait { finished_thread.alive? })
    end

    it "waits for a reply while the worker thread is running" do
      worker = Thread.new do
        sleep 0.1
        request.reply { nil }
      end

      assert(request.wait { worker.alive? })
    end

    it "yields a command it does not know, for the caller to report, then replies and carries on" do
      unknown = SemanticLogger::QueueProcessor::Request.new(:nope)
      yielded = nil

      assert(unknown.run(Object.new) { |command| yielded = command })
      assert_equal :nope, yielded
      assert(unknown.wait { finished_thread.alive? })
    end

    it "has run once it has replied, even when the block raised" do
      refute_predicate request, :ran?
      assert_raises(RuntimeError) { request.reply { raise "boom" } }
      assert_predicate request, :ran?
    end

    it "is done once, when it has run, however many times it is called" do
      calls   = 0
      request = SemanticLogger::QueueProcessor::Request.new(:flush) { calls += 1 }
      request.reply { nil }
      request.done

      assert_equal 1, calls
    end

    it "is done once when it will not run, such as one skipped behind a close" do
      calls   = 0
      request = SemanticLogger::QueueProcessor::Request.new(:flush) { calls += 1 }
      2.times { request.done }

      assert_equal 1, calls
      refute_predicate request, :ran?
    end

    it "is done once when called from many threads at the same time" do
      calls   = Queue.new
      request = SemanticLogger::QueueProcessor::Request.new(:flush) { calls << true }
      Array.new(8) { Thread.new { request.done } }.each(&:join)

      assert_equal 1, calls.size
    end

    it "returns false once the worker thread ends without replying" do
      refute(request.wait { finished_thread.alive? })
    end

    it "keeps waiting while the block says a worker can still reply" do
      replacement = nil
      first       = Thread.new do
        replacement = Thread.new do
          sleep 0.1
          request.reply { nil }
        end
      end
      first.join

      assert(request.wait { (replacement || first).alive? })
    end
  end
end
