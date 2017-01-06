require_relative 'test_helper'

class MeasureTest < Minitest::Test
  describe 'Measure' do
    before do
      SemanticLogger.default_level   = :trace
      SemanticLogger.backtrace_level = nil
      @mock_logger                   = MockLogger.new
      @appender                      = SemanticLogger.add_appender(logger: @mock_logger)
      @logger                        = SemanticLogger['LoggerTest']
      @hash                          = {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
      @hash_str                      = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
      @thread_name                   = Thread.current.name
      @file_name_reg_exp             = " #{File.basename(__FILE__)}:\d+"

      # Add mock metric subscriber
      $last_metric                   = nil
      SemanticLogger.on_metric do |log|
        $last_metric = log.dup
      end
    end

    after do
      SemanticLogger.remove_appender(@appender)
    end

    # Ensure that any log level can be measured and logged
    SemanticLogger::LEVELS.each do |level|
      level_char    = level.to_s.upcase[0]
      measure_level = "measure_#{level}".to_sym

      describe "##{measure_level}" do
        it ':message' do
          assert_equal 'result', @logger.send(measure_level, 'hello world') { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
        end

        it ':payload' do
          assert_equal 'result', @logger.send(measure_level, 'hello world', payload: @hash) { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message)
        end

        describe ':min_duration' do
          it 'not log when faster' do
            assert_equal 'result', @logger.send(measure_level, 'hello world', min_duration: 500) { 'result' } # Measure duration of the supplied block
            SemanticLogger.flush
            assert_nil @mock_logger.message
          end

          it 'log when slower' do
            assert_equal 'result', @logger.send(measure_level, 'hello world', min_duration: 200, payload: @hash) { sleep 0.5; 'result' } # Measure duration of the supplied block
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message)
          end
        end

        it ':exception' do
          assert_raises RuntimeError do
            @logger.send(measure_level, 'hello world', payload: @hash) { raise RuntimeError.new('Test') } # Measure duration of the supplied block
          end
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- Exception: RuntimeError: Test -- #{@hash_str}/, @mock_logger.message)
        end

        it ':on_exception_level' do
          assert_raises RuntimeError do
            @logger.send(measure_level, 'hello world', payload: @hash, on_exception_level: :fatal) { raise RuntimeError.new('Test') } # Measure duration of the supplied block
          end
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ F \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- Exception: RuntimeError: Test -- #{@hash_str}/, @mock_logger.message)
        end

        it ':metric' do
          metric_name = '/my/custom/metric'
          assert_equal 'result', @logger.send(measure_level, 'hello world', metric: metric_name) { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
          assert metric_name, $last_metric.metric
        end

        it ':backtrace_level' do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal 'result', @logger.send(measure_level, 'hello world') { 'result' }
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}#{@file_name_reg_exp}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
          end
        end
      end

      describe "#measure(#{level})" do
        it ':message' do
          assert_equal 'result', @logger.measure(level, 'hello world') { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
        end

        it ':payload' do
          assert_equal 'result', @logger.measure(level, 'hello world', payload: @hash) { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message)
        end

        describe ':min_duration' do
          it 'not log when faster' do
            assert_equal 'result', @logger.measure(level, 'hello world', min_duration: 1000) { 'result' } # Measure duration of the supplied block
            SemanticLogger.flush
            assert_nil @mock_logger.message
          end

          it 'log when slower' do
            assert_equal 'result', @logger.measure(level, 'hello world', min_duration: 200, payload: @hash) { sleep 0.5; 'result' } # Measure duration of the supplied block
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message)
          end
        end

        it ':exception' do
          assert_raises RuntimeError do
            @logger.measure(level, 'hello world', payload: @hash) { raise RuntimeError.new('Test') } # Measure duration of the supplied block
          end
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- Exception: RuntimeError: Test -- #{@hash_str}/, @mock_logger.message)
        end

        it ':metric' do
          metric_name = '/my/custom/metric'
          assert_equal 'result', @logger.measure(level, 'hello world', metric: metric_name) { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
          assert metric_name, $last_metric.metric
        end

        it "log #{level} info with backtrace" do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal 'result', @logger.measure(level, 'hello world') { 'result' }
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}#{@file_name_reg_exp}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
          end
        end
      end

      describe "##{measure_level} named parameters" do
        it ':message' do
          assert_equal 'result', @logger.send(measure_level, message: 'hello world') { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
        end

        it ':payload' do
          assert_equal 'result', @logger.send(measure_level, message: 'hello world', payload: @hash) { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message)
        end

        describe ':min_duration' do
          it 'not log when faster' do
            assert_equal 'result', @logger.send(measure_level, message: 'hello world', min_duration: 500) { 'result' } # Measure duration of the supplied block
            SemanticLogger.flush
            assert_nil @mock_logger.message
          end

          it 'log when slower' do
            assert_equal 'result', @logger.send(measure_level, message: 'hello world', min_duration: 200, payload: @hash) { sleep 0.5; 'result' } # Measure duration of the supplied block
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message)
          end
        end

        it ':exception' do
          assert_raises RuntimeError do
            @logger.send(measure_level, message: 'hello world', payload: @hash) { raise RuntimeError.new('Test') } # Measure duration of the supplied block
          end
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- Exception: RuntimeError: Test -- #{@hash_str}/, @mock_logger.message)
        end

        it ':on_exception_level' do
          assert_raises RuntimeError do
            @logger.send(measure_level, message: 'hello world', payload: @hash, on_exception_level: :fatal) { raise RuntimeError.new('Test') } # Measure duration of the supplied block
          end
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ F \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- Exception: RuntimeError: Test -- #{@hash_str}/, @mock_logger.message)
        end

        it ':metric' do
          metric_name = '/my/custom/metric'
          assert_equal 'result', @logger.send(measure_level, message: 'hello world', metric: metric_name) { 'result' } # Measure duration of the supplied block
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
          assert metric_name, $last_metric.metric
        end

        it ':backtrace_level' do
          SemanticLogger.stub(:backtrace_level_index, 0) do
            assert_equal 'result', @logger.send(measure_level, message: 'hello world') { 'result' }
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ #{level_char} \[\d+:#{@thread_name}#{@file_name_reg_exp}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
          end
        end
      end

    end

    describe 'return' do
      it 'log when the block performs a return' do
        assert_equal 'Good', function_with_return(@logger)
        SemanticLogger.flush
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world -- #{@hash_str}/, @mock_logger.message)
      end
    end

    describe ':silence' do
      it 'silences messages' do
        SemanticLogger.default_level = :info
        @logger.measure_info('hello world', silence: :error) do
          @logger.warn "don't log me"
        end
        SemanticLogger.flush
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
      end

      it 'does not silence higer level messages' do
        SemanticLogger.default_level = :info
        first_message                = nil
        @logger.measure_info('hello world', silence: :trace) do
          @logger.debug('hello world', @hash) { 'Calculations' }
          SemanticLogger.flush
          first_message = @mock_logger.message
        end
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, first_message)
        SemanticLogger.flush
        # Only the last log message is kept in mock logger
        assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{@thread_name}\] \((\d+\.\d+)|(\d+)ms\) LoggerTest -- hello world/, @mock_logger.message)
      end
    end

    # Make sure that measure still logs when a block uses return to return from
    # a function
    def function_with_return(logger)
      logger.measure_info('hello world', payload: @hash) do
        return 'Good'
      end
      'Bad'
    end

  end
end
