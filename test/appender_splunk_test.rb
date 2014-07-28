# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'mocha/setup'
require 'shoulda'
require 'logger'
require 'semantic_logger'

# Unit Test for SemanticLogger::Appender::Splunk
#
class AppenderSplunkTest < Test::Unit::TestCase
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
        # Stub the splunk connect call, and index call.
        setup do
          Splunk.expects(:connect).returns(Splunk::Service.new({}))
          Splunk::Service.any_instance.expects(:indexes).returns({})
        end

        should 'have default values' do
          appender = SemanticLogger::Appender::Splunk.new(username: 'username', password: 'password', index: 'index')
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