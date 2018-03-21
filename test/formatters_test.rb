require_relative 'test_helper'

class FormattersTest < Minitest::Test
  describe SemanticLogger::Formatters do
    describe '.factory' do
      let :log do
        SemanticLogger::Log.new('Test', :info)
      end

      let :appender do
        SemanticLogger::Appender::File.new(io: STDOUT)
      end

      it 'from a symbol' do
        assert formatter = SemanticLogger::Formatters.factory(:raw)
        assert formatter.is_a?(SemanticLogger::Formatters::Raw)
        assert_equal 'Test', formatter.call(log, appender)[:name]
      end

      it 'from a Hash (Symbol with options)' do
        assert formatter = SemanticLogger::Formatters.factory(raw: {time_format: '%Y%m%d'})
        assert formatter.is_a?(SemanticLogger::Formatters::Raw)
        assert result = formatter.call(log, appender)
        assert_equal 'Test', result[:name]
        assert_equal Time.now.strftime('%Y%m%d'), result[:time]
      end

      it 'from block' do
        my_formatter = ->(log, _appender) { log.name }
        assert formatter = SemanticLogger::Formatters.factory(my_formatter)
        assert formatter.is_a?(Proc)
        assert_equal 'Test', formatter.call(log, appender)
      end
    end
  end
end
