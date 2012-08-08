# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'rubygems'
require 'test/unit'
require 'shoulda'
require 'logger'
require 'mongo'
require 'sync_attr'
require 'semantic_logger/logger'
require 'semantic_logger/appender/mongodb'

# Unit Test for SemanticLogger::Appender::MongoDB
#
class AppenderMongoDBTest < Test::Unit::TestCase
  context SemanticLogger::Appender::MongoDB do
    setup do
      @db = Mongo::Connection.new['test']
    end

    context "configuration" do
      #TODO verify configuration setting carry through
    end

    context "formatter" do
      setup do
        @appender = SemanticLogger::Appender::MongoDB.new(
          :db               => @db,
          :collection_size  => 10*1024**2, # 10MB
          :host_name        => 'test',
          :application      => 'test_application'
        )
        @time = Time.parse("2012-08-02 09:48:32.482")
        @hash = { :session_id=>"HSSKLEU@JDK767", :tracking_number=>12345 }
      end

      context "format messages into text form" do
        should "handle nil level, application, message and hash" do
          document = @appender.formatter.call(nil, nil, nil, nil)
          assert_equal({ :level=>nil, :time=>document[:time], :name=>nil, :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application'}, document)
        end

        should "handle nil application, message and hash" do
          document = @appender.formatter.call(:debug, nil, nil, nil)
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>nil, :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application'}, document)
        end

        should "handle nil message and hash" do
          document = @appender.formatter.call(:debug, nil, nil, @hash)
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>nil, :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :metadata=>{:session_id=>"HSSKLEU@JDK767", :tracking_number=>12345}}, document)
        end

        should "handle nil hash" do
          document = @appender.formatter.call(:debug, 'myclass', 'hello world', nil)
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>'myclass', :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :message=>'hello world'}, document)
        end

        should "handle hash" do
          document = @appender.formatter.call(:debug, 'myclass', 'hello world', @hash)
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>'myclass', :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :message=>'hello world', :metadata=>{:session_id=>"HSSKLEU@JDK767", :tracking_number=>12345}}, document)
        end

        should "handle string block with no message" do
          document = @appender.formatter.call(:debug, 'myclass', nil, @hash, Proc.new { "Calculations" })
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>'myclass', :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :message=>'Calculations', :metadata=>{:session_id=>"HSSKLEU@JDK767", :tracking_number=>12345}}, document)
        end

        should "handle string block" do
          document = @appender.formatter.call(:debug, 'myclass', 'hello world', @hash, Proc.new { "Calculations" })
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>'myclass', :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :message=>'hello world Calculations', :metadata=>{:session_id=>"HSSKLEU@JDK767", :tracking_number=>12345}}, document)
        end

        should "handle hash block" do
          document = @appender.formatter.call(:debug, 'myclass', 'hello world', nil, Proc.new { @hash })
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>'myclass', :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :message=>'hello world', :metadata=>{:session_id=>"HSSKLEU@JDK767", :tracking_number=>12345}}, document)
        end

        should "handle string block with no other parameters" do
          document = @appender.formatter.call(:debug, 'myclass', 'hello world', @hash, Proc.new { "Calculations" })
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>'myclass', :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :message=>'hello world Calculations', :metadata=>{:session_id=>"HSSKLEU@JDK767", :tracking_number=>12345}}, document)
        end

        should "handle hash block with no other parameters" do
          document = @appender.formatter.call(:debug, nil, nil, nil, Proc.new { @hash.merge(:message => 'hello world') })
          assert_equal({ :level=>:debug, :time=>document[:time], :name=>nil, :pid=>$PID, :host_name=>"test", :thread=>document[:thread], :application=>'test_application', :message=>'hello world', :metadata=>{:session_id=>"HSSKLEU@JDK767", :tracking_number=>12345}}, document)
        end
      end
    end

    context "log to Mongo logger" do
      setup do
        @appender = SemanticLogger::Appender::MongoDB.new(
          :db               => @db,
          :collection_size  => 10*1024**2, # 10MB
          :host_name        => 'test',
          :application      => 'test_application'
        )
        @hash = { :tracking_number => 12345, :session_id => 'HSSKLEU@JDK767'}
      end

      teardown do
        @appender.purge_all
      end

      # Ensure that any log level can be logged
      SemanticLogger::Logger::LEVELS.each do |level|
        should "log #{level} information" do
          @appender.log(level, 'my_class', 'hello world', @hash) { "Calculations" }
          document = @appender.collection.find_one
          assert_equal({"_id"=>document['_id'], "level"=>level, "message"=>"hello world", "thread"=>document['thread'], "time"=>document['time'], 'metadata'=>{'session_id'=>"HSSKLEU@JDK767", 'tracking_number'=>12345}, "name"=>"my_class", "pid"=>document['pid'], "host_name"=>"test", "application"=>"test_application"}, document)
        end
      end

    end

  end
end