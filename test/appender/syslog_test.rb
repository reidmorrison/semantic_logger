require_relative "../test_helper"
require "net/tcp_client"

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
        assert_match(/<70>(.*?)SemanticLogger::Appender::Syslog -- AppenderSyslogTest log message\r\n/, message)
      end

      it "handle remote syslog over UDP" do
        message         = nil
        syslog_appender = SemanticLogger::Appender::Syslog.new(url: "udp://localhost:88888", level: :debug)
        UDPSocket.stub_any_instance(:send, ->(msg, _num, _host, _port) { message = msg }) do
          syslog_appender.debug "AppenderSyslogTest log message"
        end
        assert_match(/<70>(.*?)SemanticLogger::Appender::Syslog -- AppenderSyslogTest log message/, message)
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
