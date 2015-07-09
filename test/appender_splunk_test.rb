require_relative 'test_helper'

# Unit Test for SemanticLogger::Appender::Splunk
#
class AppenderSplunkTest < Minitest::Test
  context SemanticLogger::Appender::Splunk do

    context '#parse_options' do
      context 'argument errors' do
        should 'raise argument error for missing username' do
          error = assert_raises ArgumentError do
            SemanticLogger::Appender::Splunk.new({})
          end

          assert_equal 'Must supply a username.', error.message
        end

        should 'raise argument error for missing password' do
          error = assert_raises ArgumentError do
            SemanticLogger::Appender::Splunk.new(username: 'username')
          end

          assert_equal 'Must supply a password.', error.message
        end

        should 'raise argument error for missing index' do
          error = assert_raises ArgumentError do
            SemanticLogger::Appender::Splunk.new(username: 'username', password: 'password')
          end

          assert_equal 'Must supply an index.', error.message
        end
      end

      context 'set default values' do
        should 'have default values' do
          appender = Splunk.stub(:connect, Splunk::Service.new({})) do
            Splunk::Service.stub_any_instance(:indexes, {}) do
              SemanticLogger::Appender::Splunk.new(username: 'username', password: 'password', index: 'index')
            end
          end
          config   = appender.config
          # Default host
          assert_equal 'localhost', config[:host]
          # Default pot
          assert_equal 8089, config[:port]
          # Default scheme
          assert_equal :https, config[:scheme]
        end
      end
    end
  end
end