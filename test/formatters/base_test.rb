require_relative "../test_helper"

module SemanticLogger
  module Formatters
    class TimeFormatTestFormatter < Base
      def initialize
        super(time_format: nil)
      end
    end

    class BaseTest < Minitest::Test
      describe Base do
        let(:formatter) { TimeFormatTestFormatter.new }

        it 'when nil is passed as the formatter, the time_format property is nil' do
          assert_nil(formatter.time_format)
        end

        it 'when nil is passed as the formatter, no time will be output' do
          assert_equal(formatter.send(:format_time, Time.now), '')
        end

        it 'does suppress time output if time_format is set to nil post-initialization' do
          formatter.time_format = nil
          assert_nil(formatter.time_format)
          assert_equal(formatter.send(:format_time, Time.now), '')
        end
      end
    end
  end
end
