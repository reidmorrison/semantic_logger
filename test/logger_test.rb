require_relative 'test_helper'

# Unit Test for SemanticLogger::Logger
class LoggerTest < Minitest::Test
  describe SemanticLogger::Logger do
    before do
      # Use a mock logger that just keeps the last logged entry in an instance
      # variable
      SemanticLogger.default_level   = :trace
      SemanticLogger.backtrace_level = nil
      @mock_logger                   = MockLogger.new
      @appender                      = SemanticLogger.add_appender(logger: @mock_logger)

      # Use this test's class name as the application name in the log output
      @logger                        = SemanticLogger[LoggerTest]
      @hash                          = {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
      @hash_str                      = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
      @thread_name                   = Thread.current.name
      @file_name_reg_exp             = ' logger_test.rb:\d+'

      assert_equal [], SemanticLogger.tags
      assert_equal 65535, SemanticLogger.backtrace_level_index
    end

    after do
      SemanticLogger.remove_appender(@appender)
    end

    # Ensure that any log level can be logged
    SemanticLogger::LEVELS.each do |level|
      level_char = level.to_s.upcase[0]

      describe "##{level}" do
        describe 'positional parameter' do
          it 'logs message' do
            @logger.send(level, 'hello world')
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- hello world/, @mock_logger.message)
          end

          it 'adds message from block' do
            @logger.send(level, 'hello world') { 'Calculations' }
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- hello world -- Calculations/, @mock_logger.message)
          end

          it 'logs message and payload' do
            hash     = {tracking_number: '123456', even: 2, more: 'data'}
            hash_str = hash.inspect.sub('{', '\{').sub('}', '\}')
            @logger.send(level, 'Hello world', hash)
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- Hello world -- #{hash_str}/, @mock_logger.message)
          end

          it 'does not log an empty payload' do
            hash = {}
            @logger.send(level, 'Hello world', hash)
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- Hello world/, @mock_logger.message)
          end

          it 'logs with backtrace' do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              @logger.send(level, 'hello world', @hash) { 'Calculations' }
              SemanticLogger.flush
              assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}#{@file_name_reg_exp}\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message)
            end
          end

          it 'logs with backtrace and exception' do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              exc = RuntimeError.new('Test')
              @logger.send(level, 'hello world', exc)
              SemanticLogger.flush
              assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}#{@file_name_reg_exp}\] LoggerTest -- hello world -- Exception: RuntimeError: Test/, @mock_logger.message)
            end
          end
        end

        describe 'named parameters' do
          it 'logs message' do
            @logger.send(level, message: 'Hello world')
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- Hello world/, @mock_logger.message)
          end

          it 'logs payload and message' do
            @logger.send(level, message: 'Hello world', payload: {tracking_number: '123456', even: 2, more: 'data'})
            hash = {tracking_number: '123456', even: 2, more: 'data'}
            SemanticLogger.flush
            hash_str = hash.inspect.sub('{', '\{').sub('}', '\}')
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- Hello world -- #{hash_str}/, @mock_logger.message)
          end

          it 'logs payload and message from block' do
            @logger.send(level) { {message: 'Hello world', payload: {tracking_number: '123456', even: 2, more: 'data'}} }
            hash = {tracking_number: '123456', even: 2, more: 'data'}
            SemanticLogger.flush
            hash_str = hash.inspect.sub('{', '\{').sub('}', '\}')
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- Hello world -- #{hash_str}/, @mock_logger.message)
          end

          it 'logs payload only' do
            hash = {tracking_number: '123456', even: 2, more: 'data'}
            @logger.send(level, payload: hash)
            SemanticLogger.flush
            hash_str = hash.inspect.sub('{', '\{').sub('}', '\}')
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] LoggerTest -- #{hash_str}/, @mock_logger.message)
          end

          it 'logs duration' do
            @logger.send(level, duration: 123.45, message: 'Hello world', payload: {tracking_number: '123456', even: 2, more: 'data'})
            hash = {tracking_number: '123456', even: 2, more: 'data'}
            SemanticLogger.flush
            hash_str       = hash.inspect.sub('{', '\{').sub('}', '\}')
            duration_match = defined?(JRuby) ? '\(123ms\)' : '\(123\.5ms\)'
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] #{duration_match} LoggerTest -- Hello world -- #{hash_str}/, @mock_logger.message)
          end

          it 'does not log when below min_duration' do
            @logger.send(level, min_duration: 200, duration: 123.45, message: 'Hello world', payload: {tracking_number: '123456', even: 2, more: 'data'})
            SemanticLogger.flush
            assert_nil @mock_logger.message
          end

          it 'logs metric' do
            # Add mock metric subscriber
            $last_metric = nil
            SemanticLogger.on_metric do |log|
              $last_metric = log.dup
            end

            metric_name = '/my/custom/metric'
            @logger.send(level, metric: metric_name, duration: 123.45, message: 'Hello world', payload: {tracking_number: '123456', even: 2, more: 'data'})
            hash = {tracking_number: '123456', even: 2, more: 'data'}
            SemanticLogger.flush
            hash_str       = hash.inspect.sub('{', '\{').sub('}', '\}')
            duration_match = defined?(JRuby) ? '\(123ms\)' : '\(123\.5ms\)'
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] #{duration_match} LoggerTest -- Hello world -- #{hash_str}/, @mock_logger.message)
            assert metric_name, $last_metric.metric
          end

        end

        describe '#filter' do
          it 'Proc' do
            @appender.filter = Proc.new { |l| (/\AExclude/ =~ l.message).nil? }
            @logger.send(level, 'Exclude this log message', @hash) { 'Calculations' }
            SemanticLogger.flush
            assert_nil @mock_logger.message
          end

          it 'RegExp' do
            filter           = /\ALogger/
            @appender.filter = filter
            logger           = SemanticLogger::Logger.new('NotLogger', :trace, filter)
            logger.send(level, 'Ignore all log messages from this class', @hash) { 'Calculations' }
            SemanticLogger.flush
            assert_nil @mock_logger.message
          end
        end
      end
    end

    describe 'Compatibility' do
      # Ensure that any log level can be logged
      Logger::Severity.constants.each do |level|
        it "log Ruby logger #{level} info" do
          @logger.level = Logger::Severity.const_get(level)
          if level.to_s == 'UNKNOWN'
            assert_equal Logger::Severity.const_get('ERROR')+1, @logger.send(:level_index)
          else
            assert_equal Logger::Severity.const_get(level)+1, @logger.send(:level_index)
          end
        end
      end
    end

    describe '#level?' do
      it 'return true for debug? with :trace level' do
        SemanticLogger.default_level = :trace
        assert_equal :trace, @logger.level
        assert_equal true, @logger.debug?
        assert_equal true, @logger.trace?
      end

      it 'return false for debug? with global :debug level' do
        SemanticLogger.default_level = :debug
        assert_equal :debug, @logger.level, @logger.inspect
        assert_equal true, @logger.debug?, @logger.inspect
        assert_equal false, @logger.trace?, @logger.inspect
      end

      it 'return true for debug? with global :info level' do
        SemanticLogger.default_level = :info
        assert_equal :info, @logger.level, @logger.inspect
        assert_equal false, @logger.debug?, @logger.inspect
        assert_equal false, @logger.trace?, @logger.inspect
      end

      it 'return false for debug? with instance :debug level' do
        @logger.level = :debug
        assert_equal :debug, @logger.level, @logger.inspect
        assert_equal true, @logger.debug?, @logger.inspect
        assert_equal false, @logger.trace?, @logger.inspect
      end

      it 'return true for debug? with instance :info level' do
        @logger.level = :info
        assert_equal :info, @logger.level, @logger.inspect
        assert_equal false, @logger.debug?, @logger.inspect
        assert_equal false, @logger.trace?, @logger.inspect
      end
    end

  end
end
