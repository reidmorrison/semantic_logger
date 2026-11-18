# Runs code in a forked child process, for the tests of what an appender does there, such as with
# the connections it inherited from the parent process.
module ForkedChildHelper
  # The exit status of a forked child in which the block given to #in_forked_child skipped the test.
  SKIPPED_IN_CHILD = 2

  # Returns [String] what the block returned, run in a forked child process. Fails the test with the
  # exception, such as a failed assertion, that the block raised in the child, and skips it when the
  # block skipped it there. Skips the test where fork is not supported.
  def in_forked_child
    skip "fork is not supported" unless Process.respond_to?(:fork)

    reader, writer = IO.pipe
    pid            = fork do
      status = 1
      reader.close
      begin
        writer.write(yield)
        status = 0
      rescue Minitest::Skip => e
        writer.write(e.message)
        status = SKIPPED_IN_CHILD
      rescue StandardError, Minitest::Assertion => e
        writer.write("#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
      end
      writer.close
    ensure
      # Skips the at_exit hooks, such as the one that runs the tests, in the child.
      exit!(status)
    end
    writer.close
    output    = reader.read
    _, status = Process.wait2(pid)
    reader.close

    skip(output) if status.exitstatus == SKIPPED_IN_CHILD

    assert_predicate status, :success?, output
    output
  end
end
