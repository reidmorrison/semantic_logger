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
            bunnies << bunny
            bunny
          end
        end

        # Returns what the block returns, given an appender whose connections, including those it builds while
        # the block runs, are FakeBunny connections added to bunnies.
        def with_appender
          Bunny.stub(:new, new_bunny) do
            @appender = SemanticLogger::Appender::Rabbitmq.new(
              queue_name: "test_queue", rabbitmq_host: "localhost", metrics: false,
              formatter: ->(log, _logger) { log.message }
            )
            yield(@appender)
          end
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
          it "publishes the next entries on a new channel on the same connection, and reports the close" do
            internal_logger = SemanticLogger::Test::CaptureLogEvents.new
            output          = with_appender do |appender|
              appender.logger = internal_logger
              appender.log(log_with("one"))
              bunnies.first.channels.first.close_for_message_too_large
              appender.log(log_with("two"))
              appender.log(log_with("three"))
              connections_json
            end

            assert_equal({"published" => [%w[one two three]], "closed" => [false]}, JSON.parse(output))
            assert_equal [true, false], bunnies.first.channels.map(&:closed?)
            reports = internal_logger.events

            assert_equal 1, reports.size
            assert_equal :warn, reports.first.level
            assert_includes reports.first.message, "RabbitMQ closed the channel"
            assert_includes reports.first.message, FakeBunny::MESSAGE_TOO_LARGE
          end

          it "publishes the entry on a new channel when RabbitMQ closed the channel while it was publishing" do
            output = with_appender do |appender|
              appender.logger = SemanticLogger::Test::CaptureLogEvents.new
              appender.log(log_with("one"))
              channel = bunnies.first.channels.first
              checks  = 0
              # The appender finds the channel open, then RabbitMQ closes it before the entry is published.
              channel.stub(:closed?, -> { (checks += 1) > 1 }) { appender.log(log_with("two")) }
              connections_json
            end

            assert_equal({"published" => [%w[one two]], "closed" => [false]}, JSON.parse(output))
            assert_equal 2, bunnies.first.channels.size
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
