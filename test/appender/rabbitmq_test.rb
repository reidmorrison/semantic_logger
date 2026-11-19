require_relative "../test_helper"
require_relative "fake_bunny"
require_relative "../forked_child_helper"

module Appender
  class RabbitmqTest < Minitest::Test
    describe SemanticLogger::Appender::Rabbitmq do
      after do
        @appender&.close
      end

      it "does not show the password in #inspect" do
        Bunny.stub(:new, ->(*args) { FakeBunny.new(args) }) do
          @appender = SemanticLogger::Appender::Rabbitmq.new(
            queue_name: "test_queue", rabbitmq_host: "localhost", username: "the-username", password: "the-password",
            metrics:    true
          )
        end

        refute_includes @appender.inspect, "the-password"
        assert_includes @appender.inspect, %( queue_name="test_queue">)
      end

      describe "metrics:" do
        let(:metric_only) do
          log        = SemanticLogger::Log.new("Test", :info)
          log.metric = "users/signup"
          log
        end

        it "warns that the default changes in v6, and sends metric-only entries, when it is not supplied" do
          Bunny.stub(:new, ->(*args) { FakeBunny.new(args) }) do
            line      = __LINE__ + 3
            pattern   = /rabbitmq_test\.rb:#{line}: warning: SemanticLogger: The :rabbitmq appender/
            @appender = assert_deprecated(pattern) do
              SemanticLogger::Appender::Rabbitmq.new(queue_name: "test_queue", rabbitmq_host: "localhost")
            end
          end

          assert @appender.should_log?(metric_only)
        end

        it "leaves metric-only entries out with metrics: false, without a warning" do
          Bunny.stub(:new, ->(*args) { FakeBunny.new(args) }) do
            @appender = refute_deprecated do
              SemanticLogger::Appender::Rabbitmq.new(queue_name: "test_queue", rabbitmq_host: "localhost",
                                                     metrics: false)
            end
          end

          refute @appender.should_log?(metric_only)
        end
      end

      it "sends log messages in JSON format" do
        bunny = nil
        Bunny.stub(:new, ->(*args) { bunny = FakeBunny.new(args) }) do
          @appender = SemanticLogger::Appender::Rabbitmq.new(
            queue_name:    "test_queue",
            rabbitmq_host: "localhost",
            username:      "the-username",
            password:      "the-password",
            metrics:       true
          )

          bunny_args = bunny.args.first

          assert_equal "localhost", bunny_args[:host]
          assert_equal "the-username", bunny_args[:username]
          assert_equal "the-password", bunny_args[:password]

          message = "AppenderRabbitmqTest log message"
          @appender.info(message)
          @appender.flush

          assert_equal "test_queue", bunny.published.first[:queue]
          h = JSON.parse(bunny.published.first[:message])

          assert_equal "info", h["level"]
          assert_equal message, h["message"]
          assert_equal "SemanticLogger::Appender::Rabbitmq", h["name"]
          assert_equal $$, h["pid"]
        end
      end

      describe "#reopen" do
        include ForkedChildHelper

        # The connections that the appender built, in that order.
        let(:bunnies) { [] }
        let(:new_bunny) do
          lambda do |*args|
            bunny = FakeBunny.new(args)
            bunny.refuse_connections if @refused
            bunny.time_out_channels if @channels_time_out
            bunny.drop_on_channel_open if @dropping
            bunnies << bunny
            bunny
          end
        end

        # Returns what the block returns, given an appender whose connections, including those it builds while
        # the block runs, are FakeBunny connections added to bunnies.
        def with_appender(**options)
          Bunny.stub(:new, new_bunny) do
            @appender = SemanticLogger::Appender::Rabbitmq.new(
              queue_name: "test_queue", rabbitmq_host: "localhost", metrics: false,
              formatter: ->(log, _logger) { log.message }, **options
            )
            yield(@appender)
          end
        end

        # Runs the block while the appender waits up to the given seconds for the reason a channel was closed.
        def with_close_reason_timeout(seconds)
          klass    = SemanticLogger::Appender::Rabbitmq
          original = klass::CLOSE_REASON_TIMEOUT
          klass.send(:remove_const, :CLOSE_REASON_TIMEOUT)
          klass.const_set(:CLOSE_REASON_TIMEOUT, seconds)
          yield
        ensure
          klass.send(:remove_const, :CLOSE_REASON_TIMEOUT)
          klass.const_set(:CLOSE_REASON_TIMEOUT, original)
        end

        # Runs the block while the connections that the appender builds refuse to connect, as when RabbitMQ cannot
        # be reached.
        def while_refused
          @refused = true
          yield
        ensure
          @refused = false
        end

        # Runs the block while the connections that the appender builds start, but time out creating a channel, as
        # when RabbitMQ is overloaded.
        def while_channels_time_out
          @channels_time_out = true
          yield
        ensure
          @channels_time_out = false
        end

        def log_with(message)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log
        end

        # Returns [String] JSON with the messages published on each connection, and whether each one was closed.
        def connections_json
          JSON.generate(
            published: bunnies.map { |bunny| bunny.published.map { |published| published[:message] } },
            closed:    bunnies.map(&:closed?)
          )
        end

        it "publishes on a new channel, and closes the connection it replaced" do
          output = with_appender do |appender|
            appender.log(log_with("one"))
            appender.reopen
            appender.log(log_with("two"))
            connections_json
          end

          assert_equal({"published" => [["one"], ["two"]], "closed" => [true, false]}, JSON.parse(output))
        end

        it "reports an error closing the connection it replaced, rather than raising it" do
          internal_logger = SemanticLogger::Test::CaptureLogEvents.new
          output          = with_appender do |appender|
            appender.logger = internal_logger
            bunnies.first.stub(:close, -> { raise Bunny::ClientTimeout }) { appender.reopen }
            appender.log(log_with("two"))
            connections_json
          end

          assert_equal({"published" => [[], ["two"]], "closed" => [false, false]}, JSON.parse(output))
          report = internal_logger.events.last

          assert_equal :warn, report.level
          assert_equal "Could not close the RabbitMQ connection that a reopen replaced", report.message
          assert_instance_of Bunny::ClientTimeout, report.exception
        end

        it "closes a connection that started when creating its channel raises, and keeps the one it has" do
          output = with_appender do |appender|
            appender.log(log_with("one"))

            while_channels_time_out do
              assert_raises(Bunny::ClientTimeout) { appender.reopen }
            end
            appender.log(log_with("two"))
            connections_json
          end

          assert_equal({"published" => [%w[one two], []], "closed" => [false, true]}, JSON.parse(output))
        end

        it "raises the error creating the channel when closing that connection raises too" do
          internal_logger = SemanticLogger::Test::CaptureLogEvents.new
          with_appender do |appender|
            appender.logger = internal_logger
            FakeBunny.stub_any_instance(:close, -> { raise Bunny::ClientTimeout, "closing" }) do
              while_channels_time_out do
                error = assert_raises(Bunny::ClientTimeout) { appender.reopen }

                refute_equal "closing", error.message
              end
            end
          end
          report = internal_logger.events.last

          assert_equal "Could not close the RabbitMQ connection whose channel could not be created", report.message
          assert_equal "closing", report.exception.message
        end

        it "closes its connection, and connects again to publish, once RabbitMQ has closed its channel" do
          output = with_appender do |appender|
            appender.log(log_with("one"))
            bunnies.first.channels.first.close
            appender.close
            appender.log(log_with("two"))
            connections_json
          end

          assert_equal({"published" => [["one"], ["two"]], "closed" => [true, false]}, JSON.parse(output))
        end

        it "raises, without connecting again at once, when connecting to publish fails" do
          with_appender do |appender|
            appender.close
            built     = bunnies.size
            @dropping = true
            assert_raises(Bunny::ConnectionClosedError) { appender.log(log_with("one")) }

            assert_equal built + 1, bunnies.size, "it should connect once, not again at once"
          end
        end

        it "keeps its connection and channel when it cannot connect" do
          output = with_appender do |appender|
            appender.log(log_with("one"))

            while_refused do
              assert_raises(Bunny::TCPConnectionFailedForAllHosts) { appender.reopen }
            end
            appender.log(log_with("two"))
            appender.close
            connections_json
          end

          assert_equal({"published" => [%w[one two], []], "closed" => [true, false]}, JSON.parse(output))
        end

        it "leaves the connection and channel it inherited to the parent process after a fork" do
          output = with_appender do |appender|
            appender.log(log_with("parent"))
            in_forked_child do
              appender.reopen
              appender.log(log_with("child"))
              appender.close
              connections_json
            end
          end

          assert_equal({"published" => [["parent"], ["child"]], "closed" => [false, true]}, JSON.parse(output))
        end

        it "leaves the connection it inherited to the parent when it is closed in a child that has not reopened" do
          output = with_appender do |appender|
            appender.log(log_with("parent"))
            in_forked_child do
              appender.close
              appender.log(log_with("child"))
              connections_json
            end
          end

          assert_equal({"published" => [["parent"], ["child"]], "closed" => [false, false]}, JSON.parse(output))
        end

        it "connects to publish in a child where it could not reopen, rather than publishing on the parent's channel" do
          output = with_appender do |appender|
            appender.log(log_with("parent"))
            in_forked_child do
              while_refused do
                assert_raises(Bunny::TCPConnectionFailedForAllHosts) { appender.reopen }
              end
              appender.log(log_with("child"))
              connections_json
            end
          end

          expected = {"published" => [["parent"], [], ["child"]], "closed" => [false, false, false]}

          assert_equal expected, JSON.parse(output)
        end

        # RabbitMQ closes a channel on its own, such as with PRECONDITION_FAILED for an entry larger than its
        # max_message_size, which the appender has already published.
        describe "once RabbitMQ has closed the channel" do
          it "publishes the next entries on a new channel on the same connection, and reports the refused entry" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            output          = with_appender do |appender|
              appender.logger = internal_logger
              appender.log(log_with("one"))
              bunnies.first.channels.first.close_for_message_too_large.join
              appender.log(log_with("two"))
              appender.log(log_with("three"))
              connections_json
            end

            assert_equal({"published" => [%w[one two three]], "closed" => [false]}, JSON.parse(output))
            assert_equal [true, false], bunnies.first.channels.map(&:closed?)
            reports = internal_logger.events

            assert_equal 1, reports.size
            assert_equal :warn, reports.first.level
            assert_includes reports.first.message, "RabbitMQ refused an entry and closed the channel"
            assert_includes reports.first.message, FakeBunny::MESSAGE_TOO_LARGE
          end

          it "reports a close without a reason given as a closed channel, without saying that an entry was lost" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            output          = with_appender do |appender|
              appender.logger = internal_logger
              appender.log(log_with("one"))
              bunnies.first.channels.first.close
              appender.log(log_with("two"))
              connections_json
            end

            assert_equal({"published" => [%w[one two]], "closed" => [false]}, JSON.parse(output))
            assert_equal ["RabbitMQ closed the channel, so the entries are published on a new one. " \
                          "Reason: cannot use a closed channel! Channel id: 1"], internal_logger.events.map(&:message)
          end

          # Bunny calls on_error only for the closes that answer no operation; for the others, it names the reason
          # in Bunny::ChannelAlreadyClosed.
          it "does not wait for a reason when Bunny names it in the error" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            elapsed         = nil
            output          = with_close_reason_timeout(5) do
              with_appender do |appender|
                appender.logger = internal_logger
                appender.log(log_with("one"))
                bunnies.first.channels.first.close_with_reason("ACCESS_REFUSED - access to exchange denied")
                started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                appender.log(log_with("two"))
                elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
                connections_json
              end
            end

            assert_equal({"published" => [%w[one two]], "closed" => [false]}, JSON.parse(output))
            assert_operator elapsed, :<, 1
            messages = internal_logger.events.map(&:message)

            assert_equal 1, messages.size
            assert_includes messages.first, "RabbitMQ closed the channel"
            assert_includes messages.first, "ACCESS_REFUSED - access to exchange denied"
          end

          # Bunny marks the channel closed before it passes the channel.close to Channel#on_error, on a thread
          # of its own, so the next entry usually finds the channel closed before the reason has arrived.
          # The wait is lengthened here so that the on_error thread is always scheduled within it.
          it "waits briefly for the reason when it arrives after publishing found the channel closed" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            output          = with_close_reason_timeout(10) do
              with_appender do |appender|
                appender.logger = internal_logger
                appender.log(log_with("one"))
                late = bunnies.first.channels.first.close_for_message_too_large_after_refused_publish
                appender.log(log_with("two"))
                late.join
                connections_json
              end
            end

            assert_equal({"published" => [%w[one two]], "closed" => [false]}, JSON.parse(output))
            messages = internal_logger.events.map(&:message)

            assert_equal 1, messages.size
            assert_includes messages.first, "RabbitMQ refused an entry and closed the channel"
            assert_includes messages.first, FakeBunny::MESSAGE_TOO_LARGE
          end

          it "reports only the close of its own channel when the reason arrives after it stopped waiting" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            output          = with_appender do |appender|
              appender.logger = internal_logger
              appender.log(log_with("one"))
              gate = Thread::Queue.new
              late = bunnies.first.channels.first.close_for_message_too_large(gate)
              appender.log(log_with("two"))
              gate << true
              late.join
              bunnies.first.channels.last.close
              appender.log(log_with("three"))
              connections_json
            end

            assert_equal({"published" => [%w[one two three]], "closed" => [false]}, JSON.parse(output))
            assert_equal 3, bunnies.first.channels.size
            messages = internal_logger.events.map(&:message)

            assert_equal 2, messages.size
            messages.each do |message|
              assert_includes message, "RabbitMQ closed the channel"
              assert_includes message, "Reason: cannot use a closed channel! Channel id: 1"
              refute_includes message, FakeBunny::MESSAGE_TOO_LARGE
            end
          end

          # Bunny closes every channel of a connection that failed, and opens them again once it has recovered it.
          it "raises while Bunny recovers the connection, without replacing the channel or reporting a close" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            output          = with_appender do |appender|
              appender.logger = internal_logger
              appender.log(log_with("one"))
              bunnies.first.lose_network
              assert_raises(Bunny::ChannelAlreadyClosed) { appender.log(log_with("two")) }
              bunnies.first.recover_network
              appender.log(log_with("two"))
              connections_json
            end

            assert_equal({"published" => [%w[one two]], "closed" => [false]}, JSON.parse(output))
            assert_equal 1, bunnies.first.channels.size
            assert_empty internal_logger.events
          end

          # Bunny closes the connection once it has run out of recovery attempts, and never opens it again.
          it "publishes on a new connection once Bunny has given up recovering the connection" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            output          = with_appender do |appender|
              appender.logger = internal_logger
              appender.log(log_with("one"))
              bunnies.first.lose_network
              assert_raises(Bunny::ChannelAlreadyClosed) { appender.log(log_with("two")) }
              bunnies.first.give_up_recovery
              appender.log(log_with("two"))
              appender.log(log_with("three"))
              connections_json
            end

            assert_equal({"published" => [["one"], %w[two three]], "closed" => [true, false]}, JSON.parse(output))
            assert_equal 1, bunnies.first.channels.size
            assert_empty internal_logger.events
          end

          # Without automatic recovery, Bunny leaves a failed connection with status :open, its transport closed,
          # and its channels open, so publishing raises Bunny::ConnectionClosedError.
          it "publishes on a new connection after a network failure when automatic recovery is off" do
            output = with_appender(automatic_recovery: false) do |appender|
              appender.log(log_with("one"))
              bunnies.first.lose_network
              appender.log(log_with("two"))
              appender.log(log_with("three"))
              connections_json
            end

            assert_equal({"published" => [["one"], %w[two three]], "closed" => [true, false]}, JSON.parse(output))
          end

          it "raises when it cannot connect in place of a connection Bunny gave up, and connects for the next" do
            output = with_appender do |appender|
              appender.log(log_with("one"))
              bunnies.first.lose_network.give_up_recovery

              while_refused do
                assert_raises(Bunny::TCPConnectionFailedForAllHosts) { appender.log(log_with("two")) }
              end
              appender.log(log_with("three"))
              connections_json
            end

            expected = {"published" => [["one"], [], ["three"]], "closed" => [true, false, false]}

            assert_equal expected, JSON.parse(output)
          end

          # With automatic recovery on, Bunny passes through that same state for an instant before it recovers,
          # so it cannot be told apart from a connection.close that it does not recover, with
          # recover_from_connection_close: false, which is left to a reopen.
          it "leaves a connection with a closed transport to Bunny while automatic recovery is on" do
            output = with_appender do |appender|
              appender.log(log_with("one"))
              bunnies.first.close_transport
              assert_raises(Bunny::ConnectionClosedError) { appender.log(log_with("two")) }
              connections_json
            end

            assert_equal({"published" => [["one"]], "closed" => [false]}, JSON.parse(output))
          end

          it "closes the connection when it cannot open a new channel, and connects again for the next entry" do
            output = with_appender do |appender|
              appender.logger = SemanticLogger::Test::CaptureLogEvents.new
              appender.log(log_with("one"))
              bunnies.first.channels.first.close_for_message_too_large
              bunnies.first.time_out_channels
              assert_raises(Bunny::ClientTimeout) { appender.log(log_with("two")) }
              appender.log(log_with("three"))
              connections_json
            end

            assert_equal({"published" => [["one"], ["three"]], "closed" => [true, false]}, JSON.parse(output))
          end

          it "connects again in a forked child, rather than opening a channel on the parent's connection" do
            output = with_appender do |appender|
              appender.log(log_with("parent"))
              in_forked_child do
                bunnies.first.channels.first.close_for_message_too_large
                appender.log(log_with("child"))
                JSON.generate(parent_channels: bunnies.first.channels.size, connections: JSON.parse(connections_json))
              end
            end

            expected = {
              "parent_channels" => 1,
              "connections"     => {"published" => [["parent"], ["child"]], "closed" => [false, false]}
            }

            assert_equal expected, JSON.parse(output)
          end
        end

        it "connects again to publish once it was closed" do
          output = with_appender do |appender|
            appender.log(log_with("one"))
            appender.close
            appender.log(log_with("two"))
            connections_json
          end

          assert_equal({"published" => [["one"], ["two"]], "closed" => [true, false]}, JSON.parse(output))
        end
      end
    end
  end
end
