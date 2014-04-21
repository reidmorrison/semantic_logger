# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'mongo'
require 'semantic_logger'

# Unit Test for SemanticLogger::Appender::MongoDB
#
class AppenderMongoDBTest < Test::Unit::TestCase
  context SemanticLogger::Appender::MongoDB do
    setup do
      @db = Mongo::Connection.new['test']
      @appender = SemanticLogger::Appender::MongoDB.new(
        :db               => @db,
        :collection_size  => 10*1024**2, # 10MB
        :host_name        => 'test',
        :application      => 'test_application'
      )
      @hash = { :tracking_number => 12345, :session_id => 'HSSKLEU@JDK767'}
      @time = Time.now
    end

    teardown do
      @appender.purge_all if @appender
    end

    context "format logs into documents" do

      should "handle nil name, message and hash" do
        @appender.log SemanticLogger::Base::Log.new(:debug)
        document = @appender.collection.find_one
        assert_equal :debug, document['level']
        assert_equal nil, document['message']
        assert_equal nil, document['thread_name']
        assert_equal nil, document['time']
        assert_equal nil, document['payload']
        assert_equal $PID, document['pid']
        assert_equal 'test', document['host_name']
        assert_equal 'test_application', document['application']
      end

      should "handle nil message and payload" do
        log = SemanticLogger::Base::Log.new(:debug)
        log.payload = @hash
        @appender.log(log)

        document = @appender.collection.find_one
        assert_equal :debug, document['level']
        assert_equal nil, document['message']
        assert_equal nil, document['thread_name']
        assert_equal nil, document['time']
        assert_equal({ "tracking_number" => 12345, "session_id" => 'HSSKLEU@JDK767'}, document['payload'])
        assert_equal $PID, document['pid']
        assert_equal 'test', document['host_name']
        assert_equal 'test_application', document['application']
      end

      should "handle message and payload" do
        log = SemanticLogger::Base::Log.new(:debug)
        log.message = 'hello world'
        log.payload = @hash
        log.thread_name = 'thread'
        log.time = @time
        @appender.log(log)

        document = @appender.collection.find_one
        assert_equal :debug, document['level']
        assert_equal 'hello world', document['message']
        assert_equal 'thread', document['thread_name']
        assert_equal @time.to_i, document['time'].to_i
        assert_equal({ "tracking_number" => 12345, "session_id" => 'HSSKLEU@JDK767'}, document['payload'])
        assert_equal $PID, document['pid']
        assert_equal 'test', document['host_name']
        assert_equal 'test_application', document['application']
      end

      should "handle message without payload" do
        log = SemanticLogger::Base::Log.new(:debug)
        log.message = 'hello world'
        log.thread_name = 'thread'
        log.time = @time
        @appender.log(log)

        document = @appender.collection.find_one
        assert_equal :debug, document['level']
        assert_equal 'hello world', document['message']
        assert_equal 'thread', document['thread_name']
        assert_equal @time.to_i, document['time'].to_i
        assert_equal nil, document['payload']
        assert_equal $PID, document['pid']
        assert_equal 'test', document['host_name']
        assert_equal 'test_application', document['application']
      end
    end

    context "for each log level" do
      # Ensure that any log level can be logged
      SemanticLogger::LEVELS.each do |level|
        should "log #{level} information" do
          @appender.log SemanticLogger::Base::Log.new(level, 'thread', 'my_class', 'hello world -- Calculations', @hash, @time)
          document = @appender.collection.find_one
          assert_equal level, document['level']
          assert_equal 'hello world -- Calculations', document['message']
          assert_equal 'thread', document['thread_name']
          assert_equal @time.to_i, document['time'].to_i
          assert_equal({ "tracking_number" => 12345, "session_id" => 'HSSKLEU@JDK767'}, document['payload'])
          assert_equal $PID, document['pid']
          assert_equal 'test', document['host_name']
          assert_equal 'test_application', document['application']
        end
      end

    end

  end
end