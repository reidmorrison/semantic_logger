require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class BaseTest < Minitest::Test
      describe SemanticLogger::Formatters::Base do
        let(:log_time) do
          Time.utc(2017, 1, 14, 8, 32, 5.375276)
        end

        let(:log) do
          log      = SemanticLogger::Log.new("BaseTest", :info)
          log.time = log_time
          log
        end

        let(:formatter) do
          formatter     = SemanticLogger::Formatters::Base.new
          formatter.log = log
          formatter
        end

        describe ".build_time_format" do
          it "uses the default precision" do
            assert_equal "%Y-%m-%d %H:%M:%S.%#{SemanticLogger::Formatters::Base::PRECISION}N",
                         SemanticLogger::Formatters::Base.build_time_format
          end

          it "honours a supplied precision" do
            assert_equal "%Y-%m-%d %H:%M:%S.%3N", SemanticLogger::Formatters::Base.build_time_format(3)
          end
        end

        describe "#initialize" do
          it "defaults to the standard time format and enabled host/application/environment" do
            assert_equal SemanticLogger::Formatters::Base.build_time_format, formatter.time_format
            assert formatter.log_host
            assert formatter.log_application
            assert formatter.log_environment
            assert_equal SemanticLogger::Formatters::Base::PRECISION, formatter.precision
          end

          it "accepts overrides" do
            custom = SemanticLogger::Formatters::Base.new(
              time_format:     "%Y",
              log_host:        false,
              log_application: false,
              log_environment: false,
              precision:       3
            )
            assert_equal "%Y", custom.time_format
            refute custom.log_host
            refute custom.log_application
            refute custom.log_environment
            assert_equal 3, custom.precision
          end

          it "builds the time format from the supplied precision" do
            assert_equal "%Y-%m-%d %H:%M:%S.%3N", SemanticLogger::Formatters::Base.new(precision: 3).time_format
          end
        end

        describe "#pid" do
          it "returns the current process id" do
            assert_equal $$, formatter.pid
          end
        end

        describe "#time" do
          it "formats using the default strftime format" do
            assert_match(/\A2017-01-14 08:32:05\./, formatter.time)
          end

          it "returns nil when there is no time format" do
            formatter.time_format = nil
            assert_nil formatter.time
          end

          it "supports :ms" do
            formatter.time_format = :ms
            assert_equal (log_time.to_f * 1_000).to_i, formatter.time
          end

          it "supports :seconds" do
            formatter.time_format = :seconds
            assert_equal log_time.to_f, formatter.time
          end

          it "supports iso 8601" do
            custom     = SemanticLogger::Formatters::Base.new(time_format: :iso_8601) # rubocop:disable Naming/VariableNumber
            custom.log = log
            assert_equal log_time.utc.iso8601(custom.precision), custom.time
          end

          it "supports rfc 3339" do
            custom     = SemanticLogger::Formatters::Base.new(time_format: :rfc_3339) # rubocop:disable Naming/VariableNumber
            custom.log = log
            assert_equal log_time.utc.to_datetime.rfc3339, custom.time
          end

          it "supports :notime" do
            formatter.time_format = :notime
            assert_equal "", formatter.time
          end

          it "supports :none" do
            formatter.time_format = :none
            assert_kind_of Time, formatter.time
          end
        end
      end
    end
  end
end
