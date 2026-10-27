require_relative "../test_helper"
require "net/tcp_client"
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
