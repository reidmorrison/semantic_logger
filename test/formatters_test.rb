require_relative "test_helper"

class FormattersTest < Minitest::Test
  describe SemanticLogger::Formatters do
    describe ".factory" do
      let(:log) { SemanticLogger::Log.new("Test", :info) }
      let(:appender) { SemanticLogger::Appender::IO.new($stdout) }

      it "from a symbol" do
        assert formatter = SemanticLogger::Formatters.factory(:raw)
        assert_kind_of SemanticLogger::Formatters::Raw, formatter
        assert_equal "Test", formatter.call(log, appender)[:name]
      end

      it "from a Hash (Symbol with options)" do
        assert formatter = SemanticLogger::Formatters.factory(raw: {time_format: "%Y%m%d"})
        assert_kind_of SemanticLogger::Formatters::Raw, formatter
        assert result = formatter.call(log, appender)
        assert_equal "Test", result[:name]
        assert_equal Time.now.strftime("%Y%m%d"), result[:time]
      end

      it "from block" do
        my_formatter = ->(log, _appender) { log.name }

        assert formatter = SemanticLogger::Formatters.factory(my_formatter)
        assert_kind_of Proc, formatter
        assert_equal "Test", formatter.call(log, appender)
      end
    end

    describe "a message tagged UTF-8 with invalid bytes, as Rack decodes ?q=%1B%FF" do
      let(:appender) { SemanticLogger::Appender::IO.new($stdout) }

      %i[json raw fluentd ecs logfmt loki syslog_cee one_line].each do |name|
        it "is formatted by :#{name} without raising" do
          formatter = SemanticLogger::Formatters.factory(name)

          ["Search: \e\xFF", "\xFFabc", "Search: \xFF"].each do |text|
            log = SemanticLogger::Log.new("Search", :info)
            log.assign(message: (+text).force_encoding(Encoding::UTF_8))

            output = formatter.call(log, appender)

            assert_includes output.to_s, "Search" if text.start_with?("Search")
          end
        end
      end
    end
  end
end
