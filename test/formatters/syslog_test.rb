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

        describe "constants" do
          # The formatter defines these itself so that remote syslog works without the syslog gem.
          it "match the values of the ::Syslog constants" do
            names = %i[LOG_CRIT LOG_ERR LOG_WARNING LOG_NOTICE LOG_INFO LOG_DEBUG
                       LOG_KERN LOG_USER LOG_MAIL LOG_DAEMON LOG_AUTH LOG_SYSLOG LOG_LPR LOG_NEWS
                       LOG_UUCP LOG_CRON LOG_AUTHPRIV LOG_FTP] + (0..7).map { |i| :"LOG_LOCAL#{i}" }

            names.each do |name|
              assert_equal ::Syslog.const_get(name), SemanticLogger::Formatters::Syslog.const_get(name), name
            end
          end
        end

        describe ".require_syslog_protocol" do
          it "explains how to add the gem when it is missing" do
            missing = ->(_name) { raise LoadError, "cannot load such file -- syslog_protocol" }
            error   = SemanticLogger::Formatters::Syslog.stub(:require, missing) do
              assert_raises(LoadError) { SemanticLogger::Formatters::Syslog.require_syslog_protocol }
            end

            assert_includes error.message, 'gem "syslog_protocol"'
          end

          it "is called by both syslog formatters" do
            called = 0
            SemanticLogger::Formatters::Syslog.stub(:require_syslog_protocol, -> { called += 1 }) do
              SemanticLogger::Formatters::Syslog.new
              SemanticLogger::Formatters::SyslogCee.new
            end

            assert_equal 2, called
          end
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

          it "rejects an invalid facility set after creation" do
            formatter = SemanticLogger::Formatters::Syslog.new

            assert_raises(ArgumentError) { formatter.facility = 1 }
            assert_equal ::Syslog::LOG_USER, formatter.facility
          end

          it "sends a facility set after creation" do
            formatter.facility = ::Syslog::LOG_LOCAL0

            # local0 (16) and severity notice (5): 16 * 8 + 5
            assert_match(/\A<133>/, formatter.call(log, appender.logger))
          end

          it "escapes control characters by default" do
            assert SemanticLogger::Formatters::Syslog.new.escape_control_chars
          end

          it "allows escaping to be disabled" do
            refute SemanticLogger::Formatters::Syslog.new(escape_control_chars: false).escape_control_chars
          end
        end

        describe "control characters" do
          it "escapes embedded newlines in the packet so records cannot be forged" do
            log.message = "hello\nFORGED record"
            packet      = formatter.call(log, appender.logger)

            assert_includes packet, "hello\\nFORGED record"
            refute_includes packet, "hello\nFORGED record"
          end

          it "preserves embedded newlines when escaping is disabled" do
            appender.formatter = SemanticLogger::Formatters::Syslog.new(escape_control_chars: false)
            formatter          = appender.formatter
            formatter.max_size = appender.max_size
            log.message        = "hello\nworld"

            assert_includes formatter.call(log, appender.logger), "hello\nworld"
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

        describe ".facility_number" do
          it "converts each ::Syslog facility constant to its facility number" do
            assert_equal 0, SemanticLogger::Formatters::Syslog.facility_number(::Syslog::LOG_KERN)
            assert_equal 1, SemanticLogger::Formatters::Syslog.facility_number(::Syslog::LOG_USER)
            assert_equal 16, SemanticLogger::Formatters::Syslog.facility_number(::Syslog::LOG_LOCAL0)
            assert_equal 23, SemanticLogger::Formatters::Syslog.facility_number(::Syslog::LOG_LOCAL7)
          end

          it "rejects a value that is not a ::Syslog facility constant" do
            [1, 13, 23 << 4, "user", nil].each do |facility|
              assert_raises(ArgumentError) { SemanticLogger::Formatters::Syslog.facility_number(facility) }
            end
          end

          it "rejects an invalid facility when the formatter is created" do
            assert_raises(ArgumentError) { SemanticLogger::Formatters::Syslog.new(facility: 1) }
          end
        end

        describe "max_size" do
          it "defaults to 1024 bytes" do
            assert_equal 1024, SemanticLogger::Formatters::Syslog.new.max_size
          end

          it "formats with the default when none is supplied" do
            packet = SemanticLogger::Formatters::Syslog.new.call(log, appender.logger)

            assert_includes packet, "hello world"
          end

          it "truncates a packet to max_size" do
            log.message = "x" * 2000
            packet      = SemanticLogger::Formatters::Syslog.new(max_size: 100).call(log, appender.logger)

            assert_equal 100, packet.bytesize
          end
        end

        describe "#call" do
          # PRI is facility number * 8 + severity; info maps to LOG_NOTICE (5) by default.
          it "sends the user facility by default" do
            assert_match(/\A<13>/, formatter.call(log, appender.logger))
          end

          it "sends the supplied facility" do
            local0 = SemanticLogger::Formatters::Syslog.new(facility: ::Syslog::LOG_LOCAL0, max_size: 1024)

            assert_match(/\A<133>/, local0.call(log, appender.logger))
          end

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
