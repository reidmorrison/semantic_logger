# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'mocha/setup'
require 'semantic_logger'
require 'socket'
require 'resilient_socket'
require 'syslog_protocol'

# Unit Test for SemanticLogger::Appender::Syslog
#
class AppenderSyslogTest < Test::Unit::TestCase
  context SemanticLogger::Appender::Syslog do

    should 'handle local syslog' do
      ::Syslog.expects(:open).once
      ::Syslog.expects(:log).once
      syslog_appender = SemanticLogger::Appender::Syslog.new
      syslog_appender.debug 'AppenderSyslogTest log message'
    end

    should 'handle remote syslog over TCP' do
      ::ResilientSocket::TCPClient.any_instance.stubs('closed?').returns(false)
      ::ResilientSocket::TCPClient.any_instance.stubs('connect')
      ::ResilientSocket::TCPClient.any_instance.expects(:write).with{ |message| message =~ /<70>(.*?)SemanticLogger::Appender::Syslog -- AppenderSyslogTest log message\r\n/ }
      syslog_appender = SemanticLogger::Appender::Syslog.new(:server => 'tcp://localhost:88888')
      syslog_appender.debug 'AppenderSyslogTest log message'
    end

    should 'handle remote syslog over UDP' do
      ::UDPSocket.any_instance.expects(:send).with{ |*params| params[0] =~ /<70>(.*?)SemanticLogger::Appender::Syslog -- AppenderSyslogTest log message/ }
      syslog_appender = SemanticLogger::Appender::Syslog.new(:server => 'udp://localhost:88888')
      syslog_appender.debug 'AppenderSyslogTest log message'
    end

    # Should be able to log each level.
    SemanticLogger::LEVELS.each do |level|
      should "log #{level} information" do
        ::Syslog.expects(:open).once
        ::Syslog.expects(:log).once
        syslog_appender = SemanticLogger::Appender::Syslog.new
        syslog_appender.send(level, 'AppenderSyslogTest #{level.to_s} message')
      end
    end

    should "allow logging with %" do
      message = "AppenderSyslogTest %test"
      syslog_appender = SemanticLogger::Appender::Syslog.new

      assert_nothing_raised ArgumentError do
        syslog_appender.debug(message)
      end
    end

  end
end
