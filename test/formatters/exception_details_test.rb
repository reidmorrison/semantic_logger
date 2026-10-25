require_relative "../test_helper"

module SemanticLogger
  module Formatters
    # The `log_exception_details` option, across the formatters.
    class ExceptionDetailsTest < Minitest::Test
      # Supplies its own detail, the same way on every Ruby version.
      class DetailedError < StandardError
        def detailed_message(highlight: false, **)
          "#{super}\n  order_id: 42"
        end
      end

      describe "log_exception_details" do
        let(:log) do
          log = SemanticLogger::Log.new("ExceptionDetailsTest", :error)
          begin
            raise DetailedError, "Order rejected"
          rescue DetailedError => e
            log.exception = e
          end
          log
        end

        let(:appender) { SemanticLogger::Appender::IO.new(StringIO.new) }

        def format(formatter)
          formatter.call(log, appender)
        end

        describe "Default" do
          it "logs the details on the line after the exception message" do
            output = format(Default.new)

            assert_includes output, "-- Exception: #{DetailedError}: Order rejected\n  order_id: 42\n"
          end

          it "omits the details when disabled" do
            output = format(Default.new(log_exception_details: false))

            assert_includes output, "-- Exception: #{DetailedError}: Order rejected\n"
            refute_includes output, "order_id"
          end

          it "escapes control characters in the details when escaping is enabled" do
            multi_line_error = Class.new(StandardError) do
              def detailed_message(highlight: false, **)
                "#{super}\n  first\n  second"
              end
            end
            begin
              raise multi_line_error, "boom"
            rescue StandardError => e
              log.exception = e
            end

            assert_includes format(Default.new(escape_control_chars: true)), "boom\n  first\\n  second\n"
          end

          it "omits the source snippet unless requested" do
            user_name = "jack"
            begin
              user_name.upcas
            rescue NoMethodError => e
              log.exception = e
            end

            assert_match(/Did you mean\?  upcase/, format(Default.new))
            refute_includes format(Default.new), "user_name.upcas"
            assert_includes format(Default.new(log_exception_details: :with_source)), "user_name.upcas"
          end
        end

        it "Color logs the details" do
          assert_includes format(Color.new), "Order rejected#{AnsiColors::CLEAR}\n  order_id: 42\n"
        end

        it "OneLine does not log the details" do
          refute_includes format(OneLine.new), "order_id"
        end

        describe "Raw" do
          it "does not log the details by default" do
            refute format(Raw.new)[:exception].key?(:details)
          end

          it "logs the details when enabled" do
            exception = format(Raw.new(log_exception_details: true))[:exception]

            assert_equal "Order rejected", exception[:message]
            assert_equal "  order_id: 42", exception[:details]
          end

          it "logs the details of each cause" do
            begin
              begin
                raise DetailedError, "the cause"
              rescue DetailedError
                raise "the effect"
              end
            rescue RuntimeError => e
              log.exception = e
            end
            exception = format(Raw.new(log_exception_details: true))[:exception]

            refute exception.key?(:details)
            assert_equal "  order_id: 42", exception[:cause][:details]
          end
        end

        it "Json logs the details when enabled" do
          json = JSON.parse(format(Json.new(log_exception_details: true)))

          assert_equal "  order_id: 42", json["exception"]["details"]
        end
      end
    end
  end
end
