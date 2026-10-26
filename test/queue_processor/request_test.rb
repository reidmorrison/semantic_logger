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
