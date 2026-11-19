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

        it "connects to the server in the url, rather than one given in tcp_client:" do
          appender = appender_with({server: "otherhost:514"})

          assert_equal ["localhost:8514"], appender.remote_syslog.servers
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
