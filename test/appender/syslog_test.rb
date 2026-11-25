require_relative "../test_helper"
require "net/tcp_client"
require_relative "../forked_child_helper"
require_relative "../tls_server"
require "syslog"

# Unit Test for SemanticLogger::Appender::Syslog
#
module Appender
  class SyslogTest < Minitest::Test
    describe SemanticLogger::Appender::Syslog do
      it "handle local syslog" do
        message = nil
        Syslog.stub(:open, nil) do
          Syslog.stub(:log, ->(_level, msg) { message = msg }) do
            syslog_appender = SemanticLogger::Appender::Syslog.new(level: :debug)
            syslog_appender.debug "AppenderSyslogTest log message"
          end
        end

        assert_match(/^ D (.*?) SemanticLogger::Appender::Syslog -- AppenderSyslogTest log message/, message)
      end

      it "does not add exception details to local syslog records" do
        formatter = Syslog.stub(:open, nil) { SemanticLogger::Appender::Syslog.new.formatter }

        refute formatter.log_exception_details
      end

      it "raises for a nil url, rather than logging to the local syslog" do
        assert_raises(URI::InvalidURIError) { SemanticLogger::Appender::Syslog.new(url: nil) }
      end

      it "handle remote syslog over TCP" do
        message = nil
        Net::TCPClient.stub_any_instance(:closed?, false) do
          Net::TCPClient.stub_any_instance(:connect, nil) do
            syslog_appender = SemanticLogger::Appender::Syslog.new(url: "tcp://localhost:88888", level: :debug)
            syslog_appender.remote_syslog.stub(:write, proc { |data| message = data }) do
              syslog_appender.debug "AppenderSyslogTest log message"
            end
          end
        end

        # Facility user (1) and severity info (6): 1 * 8 + 6
        assert_match(/<14>(.*?)SemanticLogger::Appender::Syslog -- AppenderSyslogTest log message\r\n/, message)
      end

      it "handle remote syslog over UDP" do
        message         = nil
        syslog_appender = SemanticLogger::Appender::Syslog.new(url: "udp://localhost:88888", level: :debug)
        UDPSocket.stub_any_instance(:send, ->(msg, _num, _host, _port) { message = msg }) do
          syslog_appender.debug "AppenderSyslogTest log message"
        end

        assert_match(/<14>(.*?)SemanticLogger::Appender::Syslog -- AppenderSyslogTest log message/, message)
      end

      describe "tcp_client:" do
        # Returns [SemanticLogger::Appender::Syslog] an appender over TCP built with the given tcp_client: option,
        # which connects to nothing.
        def appender_with(tcp_client)
          Net::TCPClient.stub_any_instance(:connect, nil) do
            SemanticLogger::Appender::Syslog.new(url: "tcp://localhost:8514", tcp_client: tcp_client)
          end
        end

        it "gives net_tcp_client its own logger, with benchmark_* methods that do not warn, when it is outdated" do
          options  = SemanticLogger::Appender::TcpClientOptions
          appender = options.stub(:report_outdated_gem, ->(name) { name == ":syslog" }) { appender_with({}) }

          assert_same appender.logger, appender.remote_syslog.logger
          assert_kind_of options::BenchmarkWithoutWarning, appender.remote_syslog.logger
          refute_kind_of options::BenchmarkWithoutWarning, Net::TCPClient.logger
        end

        it "keeps the ssl: handshake_timeout after a reopen, and leaves the Hashes given as they are" do
          ssl        = {handshake_timeout: 2}
          tcp_client = {connect_timeout: 3, ssl: ssl}
          appender   = appender_with(tcp_client)

          assert_in_delta 2.0, appender.remote_syslog.ssl_handshake_timeout

          Net::TCPClient.stub_any_instance(:connect, nil) { appender.reopen }

          assert_in_delta 2.0, appender.remote_syslog.ssl_handshake_timeout
          assert_equal ["localhost:8514"], appender.remote_syslog.servers
          assert_equal({connect_timeout: 3, ssl: {handshake_timeout: 2}}, tcp_client)
        end

        it "accepts frozen Hashes" do
          appender = appender_with({connect_timeout: 3, ssl: {handshake_timeout: 2}.freeze}.freeze)

          assert_in_delta 2.0, appender.remote_syslog.ssl_handshake_timeout
          assert_equal ["localhost:8514"], appender.remote_syslog.servers
        end

        it "connects to the server in the url, rather than one given in tcp_client:, which is deprecated" do
          appender = assert_deprecated(/:syslog appender's server: is deprecated.*server: it is ignored/) do
            appender_with({server: "otherhost:514"})
          end

          assert_equal ["localhost:8514"], appender.remote_syslog.servers
        end

        it "warns that servers: in tcp_client: is deprecated, since it replaces the server of the url" do
          appender = assert_deprecated(/servers: it replaces the server of the url, which v6 always connects to/) do
            appender_with({servers: ["otherhost:514"]})
          end

          assert_equal ["otherhost:514"], appender.remote_syslog.servers
        end

        it "takes tcp_client: nil as no options" do
          appender = refute_deprecated { appender_with(nil) }

          assert_equal ["localhost:8514"], appender.remote_syslog.servers
        end

        it "warns, at the line that added it, that the retry options of tcp_client: are deprecated" do
          line     = __LINE__ + 4
          warning  = /syslog_test\.rb:#{line}: warning: SemanticLogger: The :syslog appender's retry_count: /
          appender = assert_deprecated(warning) do
            Net::TCPClient.stub_any_instance(:connect, nil) do
              SemanticLogger.add_appender(appender: :syslog, url: "tcp://localhost:8514", tcp_client: {retry_count: 1})
            end
          end
        ensure
          SemanticLogger.remove_appender(appender) if appender
        end

        it "does not warn for the options that v6 keeps" do
          refute_deprecated do
            appender_with({connect_timeout: 3, write_timeout: 4, keepalive: true, policy: :random, ssl: nil})
          end
        end
      end

      describe "over TCP with TLS, after a fork" do
        include ForkedChildHelper

        let(:server) { TlsServer.new(separator: "\r\n") }
        let(:tls_appender) do
          SemanticLogger::Appender::Syslog.new(
            url:        "tcp://127.0.0.1:#{server.port}",
            tcp_client: {ssl: {verify_mode: OpenSSL::SSL::VERIFY_NONE}},
            formatter:  ->(log, _logger) { log.message }
          )
        end

        after do
          tls_appender.remote_syslog&.close
          server.close
        end

        def log_with(message)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log
        end

        it "leaves the connection it inherited to the parent process, and connects again in the child" do
          tls_appender.log(log_with("before"))
          in_forked_child do
            tls_appender.reopen
            tls_appender.log(log_with("child"))
            ""
          end
          tls_appender.log(log_with("after"))

          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end

        it "connects in the child when a reopen there cannot, rather than writing through the parent's connection" do
          tls_appender.log(log_with("before"))
          output = in_forked_child do
            error = Net::TCPClient.stub(:new, ->(**) { raise Errno::ECONNREFUSED }) do
              tls_appender.reopen
            rescue Errno::ECONNREFUSED => e
              e
            end
            tls_appender.log(log_with("child"))
            error.class.name
          end
          tls_appender.log(log_with("after"))

          assert_equal "Errno::ECONNREFUSED", output
          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end

        it "leaves the connection it inherited to the parent when it is closed in a child that has not reopened" do
          tls_appender.log(log_with("before"))
          in_forked_child do
            tls_appender.close
            tls_appender.log(log_with("child"))
            ""
          end
          tls_appender.log(log_with("after"))

          assert_equal %w[before after], server.received(1, 2)
          assert_equal ["child", :closed], server.received(2, 2)
        end
      end

      describe "over TCP, after a fork" do
        include ForkedChildHelper

        let(:server) { TCPServer.new("127.0.0.1", 0) }
        let(:tcp_appender) { SemanticLogger::Appender::Syslog.new(url: "tcp://127.0.0.1:#{server.addr[1]}") }

        after do
          server.close
        end

        it "closes its copy of the connection it inherited, so the server sees it end once the parent closes it" do
          tcp_appender
          inherited = server.accept
          ended     = while_forked_child_runs(-> { tcp_appender.reopen }) do
            tcp_appender.remote_syslog.close
            inherited.wait_readable(2) && inherited.read_nonblock(1, exception: false).nil?
          end

          assert ended, "The server did not see the connection end while the child process was running"
        ensure
          inherited&.close
        end
      end

      describe "over TCP, reopened or closed in the same process" do
        let(:server) { TCPServer.new("127.0.0.1", 0) }
        let(:tcp_appender) do
          SemanticLogger::Appender::Syslog.new(
            url:       "tcp://127.0.0.1:#{server.addr[1]}",
            formatter: ->(log, _logger) { log.message }
          )
        end

        after do
          tcp_appender.close
          server.close
        end

        def log_with(message)
          log         = SemanticLogger::Log.new("Test", :info)
          log.message = message
          log
        end

        # Returns [true|false] whether the server sees the given connection end within 2 seconds.
        def ended?(connection)
          connection.wait_readable(2) && connection.read_nonblock(1, exception: false).nil?
        end

        # Returns [String] the next record that the given connection reads, within 2 seconds.
        def record(connection)
          connection.wait_readable(2) && connection.gets("\r\n")
        end

        it "closes the connection that a reopen replaced, and writes on the new one" do
          tcp_appender
          replaced = server.accept
          tcp_appender.reopen
          current = server.accept
          tcp_appender.log(log_with("after"))

          assert ended?(replaced), "The server did not see the replaced connection end"
          assert_equal "after\r\n", record(current)
        ensure
          [replaced, current].each { |connection| connection&.close }
        end

        it "keeps the connection it has when a reopen cannot connect" do
          tcp_appender
          connection = server.accept

          Net::TCPClient.stub(:new, ->(**) { raise Errno::ECONNREFUSED }) do
            assert_raises(Errno::ECONNREFUSED) { tcp_appender.reopen }
          end
          tcp_appender.log(log_with("after"))

          assert_equal "after\r\n", record(connection)
        ensure
          connection&.close
        end

        it "reports an error closing the connection that a reopen replaced, rather than raising it" do
          internal_logger       = SemanticLogger::Test::CaptureLogEvents.new
          tcp_appender.logger   = internal_logger
          replaced              = tcp_appender.remote_syslog
          replaced.stub(:close, -> { raise Errno::ECONNRESET }) { tcp_appender.reopen }
          report = internal_logger.events.last

          assert_equal :warn, report.level
          assert_equal "Could not close the connection to the syslog server that a reopen replaced", report.message
          assert_instance_of Errno::ECONNRESET, report.exception
        ensure
          replaced&.close
        end

        it "closes its connection, and connects again for the next write" do
          tcp_appender
          closed = server.accept
          tcp_appender.close

          assert ended?(closed), "The server did not see the connection end"

          tcp_appender.log(log_with("after"))
          current = server.accept

          assert_equal "after\r\n", record(current)
        ensure
          [closed, current].each { |connection| connection&.close }
        end
      end

      describe "over UDP" do
        it "closes the socket that a reopen replaced, and its socket when it is closed" do
          appender = SemanticLogger::Appender::Syslog.new(url: "udp://127.0.0.1:514")
          replaced = appender.remote_syslog
          appender.reopen

          assert_predicate replaced, :closed?
          current = appender.remote_syslog

          refute_predicate current, :closed?

          appender.close

          assert_predicate current, :closed?
        end

        it "opens a new socket to write after it is closed" do
          server = UDPSocket.new
          server.bind("127.0.0.1", 0)
          appender = SemanticLogger::Appender::Syslog.new(
            url:       "udp://127.0.0.1:#{server.addr[1]}",
            formatter: ->(log, _logger) { log.message }
          )
          appender.close
          appender.flush
          appender.log(SemanticLogger::Log.new("Test", :info).tap { |log| log.message = "after" })

          assert server.wait_readable(2), "The server did not receive the message"
          assert_equal "after", server.recv(65_536)
        ensure
          appender&.close
          server&.close
        end
      end

      describe "#message_error?" do
        it "is true over UDP for a log message too large to send as a datagram" do
          appender = SemanticLogger::Appender::Syslog.new(url: "udp://localhost:88888")

          assert appender.message_error?(Errno::EMSGSIZE.new)
          refute appender.message_error?(Errno::ECONNREFUSED.new)
        end

        it "is false over TCP, where the message is not sent as one datagram" do
          Net::TCPClient.stub_any_instance(:connect, nil) do
            appender = SemanticLogger::Appender::Syslog.new(url: "tcp://localhost:88888")

            refute appender.message_error?(Errno::EMSGSIZE.new)
          end
        end
      end

      it "accepts a level_map hash for local syslog" do
        severity = nil
        Syslog.stub(:open, nil) do
          Syslog.stub(:log, ->(level, _msg) { severity = level }) do
            syslog_appender = SemanticLogger::Appender::Syslog.new(level_map: {warn: ::Syslog::LOG_ALERT})
            syslog_appender.info "AppenderSyslogTest log message"
          end
        end

        assert_equal ::Syslog::LOG_NOTICE, severity
      end

      describe "with a remote syslog formatter named by formatter:" do
        let(:options) do
          {url: "udp://localhost:88888", facility: ::Syslog::LOG_LOCAL0, level_map: {info: ::Syslog::LOG_ALERT}}
        end

        it "passes its facility and level map to :syslog" do
          formatter = SemanticLogger::Appender::Syslog.new(formatter: :syslog, **options).formatter

          assert_equal ::Syslog::LOG_LOCAL0, formatter.facility
          assert_equal ::Syslog::LOG_ALERT, formatter.level_map[:info]
        end

        it "passes its facility and level map to :syslog_cee" do
          formatter = SemanticLogger::Appender::Syslog.new(formatter: {syslog_cee: {}}, **options).formatter

          assert_equal ::Syslog::LOG_LOCAL0, formatter.facility
          assert_equal ::Syslog::LOG_ALERT, formatter.level_map[:info]
        end

        it "passes its maximum packet size" do
          formatter = SemanticLogger::Appender::Syslog.new(formatter: :syslog_cee, max_size: 2048, **options).formatter

          assert_equal 2048, formatter.max_size
        end

        it "lets the formatter's own options take precedence" do
          formatter = SemanticLogger::Appender::Syslog.new(
            formatter: {syslog: {facility: ::Syslog::LOG_LOCAL1}}, **options
          ).formatter

          assert_equal ::Syslog::LOG_LOCAL1, formatter.facility
        end

        it "passes its facility, level map, and maximum packet size when the formatter is changed later" do
          appender = SemanticLogger::Appender::Syslog.new(max_size: 2048, **options)
          appender.formatter = :syslog_cee
          formatter = appender.formatter

          assert_instance_of SemanticLogger::Formatters::SyslogCee, formatter
          assert_equal ::Syslog::LOG_LOCAL0, formatter.facility
          assert_equal ::Syslog::LOG_ALERT, formatter.level_map[:info]
          assert_equal 2048, formatter.max_size
        end

        it "rejects an invalid facility even with another formatter" do
          assert_raises(ArgumentError) do
            SemanticLogger::Appender::Syslog.new(url: "udp://localhost:88888", facility: 1, formatter: :json)
          end
        end
      end

      # Should be able to log each level.
      SemanticLogger::LEVELS.each do |level|
        it "log #{level} information" do
          Syslog.stub(:open, nil) do
            Syslog.stub(:log, nil) do
              syslog_appender = SemanticLogger::Appender::Syslog.new
              syslog_appender.send(level, "AppenderSyslogTest #{level} message")
            end
          end
        end
      end

      it "allow logging with %" do
        message         = "AppenderSyslogTest %test"
        syslog_appender = SemanticLogger::Appender::Syslog.new
        syslog_appender.debug(message)
      end
    end
  end
end
