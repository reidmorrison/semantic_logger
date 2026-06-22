require_relative "../test_helper"
require "syslog"

module SemanticLogger
  module Formatters
    class SyslogTest < Minitest::Test
      describe SemanticLogger::Formatters::Syslog do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:log) do
          log         = SemanticLogger::Log.new("SyslogFormatterTest", :info)
          log.time    = log_time
          log.message = "hello world"
          log
        end

        let(:appender) do
          SemanticLogger::Appender::Syslog.new(formatter: :syslog)
        end

        let(:formatter) do
          formatter          = appender.formatter
          formatter.max_size = appender.max_size
          formatter
        end

        describe "#initialize" do
          it "defaults the facility to LOG_USER" do
            assert_equal ::Syslog::LOG_USER, SemanticLogger::Formatters::Syslog.new.facility
          end

          it "uses a default LevelMap" do
            assert_instance_of SemanticLogger::Formatters::Syslog::LevelMap, formatter.level_map
          end

          it "converts a level_map hash into a LevelMap" do
            mapped = SemanticLogger::Formatters::Syslog.new(level_map: {warn: ::Syslog::LOG_NOTICE})

            assert_instance_of SemanticLogger::Formatters::Syslog::LevelMap, mapped.level_map
            assert_equal ::Syslog::LOG_NOTICE, mapped.level_map[:warn]
            # Unspecified levels keep their defaults.
            assert_equal ::Syslog::LOG_CRIT, mapped.level_map[:fatal]
          end

          it "accepts a LevelMap instance" do
            level_map = SemanticLogger::Formatters::Syslog::LevelMap.new(info: ::Syslog::LOG_ALERT)
            mapped    = SemanticLogger::Formatters::Syslog.new(level_map: level_map)

            assert_same level_map, mapped.level_map
          end
        end

        describe SemanticLogger::Formatters::Syslog::LevelMap do
          it "maps the default semantic levels to syslog levels" do
            map = SemanticLogger::Formatters::Syslog::LevelMap.new

            assert_equal ::Syslog::LOG_DEBUG,   map[:trace]
            assert_equal ::Syslog::LOG_INFO,    map[:debug]
            assert_equal ::Syslog::LOG_NOTICE,  map[:info]
            assert_equal ::Syslog::LOG_WARNING, map[:warn]
            assert_equal ::Syslog::LOG_ERR,     map[:error]
            assert_equal ::Syslog::LOG_CRIT,    map[:fatal]
          end

          it "allows individual levels to be overridden" do
            map = SemanticLogger::Formatters::Syslog::LevelMap.new(warn: ::Syslog::LOG_NOTICE)

            assert_equal ::Syslog::LOG_NOTICE, map[:warn]
            assert_equal ::Syslog::LOG_ERR,    map[:error]
          end
        end

        describe "#time" do
          it "returns nil since the time is part of the syslog packet" do
            assert_nil formatter.time
          end
        end

        describe "#call" do
          it "wraps the message in a syslog packet" do
            packet = formatter.call(log, appender.logger)

            assert_includes packet, "hello world"
            assert_includes packet, appender.logger.host
          end

          it "uses the application name as the syslog tag without spaces" do
            packet = formatter.call(log, appender.logger)

            assert_includes packet, appender.logger.application.delete(" ")
          end
        end
      end
    end
  end
end
