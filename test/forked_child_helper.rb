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

  # Returns [Object] what the block returned, run in this process while a forked child process is still
  # running, once the given Proc has run in the child, such as to close a connection that the child
  # inherited too. The child waits for the block to return, for up to 5 seconds, before it exits. Fails and
  # skips the test as #in_forked_child does.
  def while_forked_child_runs(child)
    ready_reader, ready_writer = IO.pipe
    done_reader, done_writer   = IO.pipe
    parent                     = Thread.new do
      ready_reader.wait_readable(5)
      yield
    ensure
      done_writer.close
    end
    in_forked_child do
      done_writer.close
      child.call
      ready_writer.write("ready")
      done_reader.wait_readable(5)
      ""
    end
    parent.value
  ensure
    parent&.kill&.join
    [ready_reader, ready_writer, done_reader, done_writer].each { |io| io.close unless io.closed? }
  end
end
