require_relative 'test_helper'

# Unit Test for SemanticLogger::Logger
class LoggerTest < Minitest::Test
  describe SemanticLogger::Logger do
    include InMemoryAppenderHelper

    let :dimensions do
      {action: 'hit', user: 'jbloggs', state: 'FL'}
    end

    # Ensure that any log level can be logged
    SemanticLogger::LEVELS.each do |level|
      describe "##{level}" do
        describe 'positional parameter' do
          it 'logs message' do
            logger.send(level, 'hello world')

            assert log = log_message
            assert_equal 'hello world', log.message
          end

          it 'adds message from block' do
            logger.send(level, 'hello world') { 'Calculations' }

            assert log = log_message
            assert_equal 'hello world -- Calculations', log.message
          end

          it 'logs message and payload' do
            logger.send(level, 'hello world', payload)

            assert log = log_message
            assert_equal 'hello world', log.message
            assert_equal payload, log.payload
          end

          it 'logs with backtrace' do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              logger.send(level, 'hello world', payload) { 'Calculations' }

              assert log = log_message
              assert_equal 'hello world -- Calculations', log.message
              assert_equal payload, log.payload
              assert log.backtrace
              assert log.backtrace.size.positive?, log.backtrace
            end
          end

          it 'logs with backtrace and exception' do
            SemanticLogger.stub(:backtrace_level_index, 0) do
              exc = RuntimeError.new('Test')
              logger.send(level, 'hello world', exc)

              assert log = log_message
              assert_equal 'hello world', log.message
              assert log.backtrace
              assert log.backtrace.size.positive?, log.backtrace

              assert log.exception
              refute log.exception.backtrace
              assert_equal 'RuntimeError', log.exception.class.name
            end
          end
        end

        describe 'keyword arguments' do
          it 'logs message' do
            logger.send(level, message: 'hello world')

            assert log = log_message
            assert_equal 'hello world', log.message
          end

          it 'logs payload and message' do
            logger.send(level, message: 'hello world', payload: payload)

            assert log = log_message
            assert_equal 'hello world', log.message
            assert_equal payload, log.payload
          end

          it 'logs payload and message from block' do
            logger.send(level) { {message: 'hello world', payload: payload} }

            assert log = log_message
            assert_equal 'hello world', log.message
            assert_equal payload, log.payload
          end

          it 'logs payload from block' do
            logger.send(level) { { 'test_key1' => 'hello world', 'test_key2' => payload} }

            assert log = log_message
            assert_equal log.payload, { 'test_key1' => 'hello world', 'test_key2' => payload }
          end

          it 'logs payload only' do
            logger.send(level, payload: payload)

            assert log = log_message
            refute log.message
            assert_equal payload, log.payload
          end

          it 'logs duration' do
            logger.send(level, duration: 123.44, message: 'hello world', payload: payload)

            assert log = log_message
            assert_equal 'hello world', log.message
            assert_equal payload, log.payload
            assert_equal 123.44, log.duration
          end

          it 'does not log when below min_duration' do
            logger.send(level, min_duration: 200, duration: 123.45, message: 'hello world', payload: {tracking_number: '123456', even: 2, more: 'data'})

            refute log_message
          end

          it 'logs metric' do
            metric_name = '/my/custom/metric'
            logger.send(level, metric: metric_name, duration: 123.44, message: 'hello world', payload: payload)

            assert log = log_message
            assert_equal 'hello world', log.message
            assert_equal payload, log.payload
            assert_equal 123.44, log.duration
            assert_equal metric_name, log.metric
          end

          describe 'metrics appender' do
            let :appender do
              InMemoryMetricsAppender.new
            end

            it 'logs metric only events' do
              metric_name = '/my/custom/metric'
              logger.send(level, metric: metric_name, dimensions: dimensions)

              assert log = log_message
              assert_equal metric_name, log.metric
              assert_equal dimensions, log.dimensions
              refute log.message
            end
          end

          it 'for compatibility handles random payload logged as keyword arguments' do
            logger.send(level, payload)

            assert log = log_message
            refute log.message
            refute log.exception
            refute log.metric
            assert_equal payload, log.payload
          end
        end

        describe '#filter' do
          describe 'at the appender level' do
            it 'Proc' do
              appender.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, 'Exclude this log message', @hash) { 'Calculations' }

              refute log_message
            end

            it 'RegExp' do
              filter          = /\ALogger/
              appender.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, 'Exclude this log message', @hash) { 'Calculations' }

              refute log_message
            end
          end

          describe 'at the logger level' do
            it 'Proc' do
              logger.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, 'Exclude this log message', @hash) { 'Calculations' }

              refute log_message
            end

            it 'RegExp' do
              filter        = /\ALogger/
              logger.filter = ->(log) { (/\AExclude/ =~ log.message).nil? }
              logger.send(level, 'Exclude this log message', @hash) { 'Calculations' }

              refute log_message
            end
          end
        end
      end
    end

    describe 'when level is too high' do
      it 'does not log' do
        SemanticLogger.default_level = :error
        logger.info('Exclude this log message')

        refute log_message
      end
    end

    describe 'Compatibility' do
      # Ensure that any log level can be logged
      Logger::Severity.constants.each do |level|
        it "log Ruby logger #{level} info" do
          logger.level = Logger::Severity.const_get(level)
          if level.to_s == 'UNKNOWN'
            assert_equal Logger::Severity.const_get('ERROR') + 1, logger.send(:level_index)
          else
            assert_equal Logger::Severity.const_get(level) + 1, logger.send(:level_index)
          end
        end
      end
    end

    describe '#level?' do
      it 'return true for debug? with :trace level' do
        SemanticLogger.default_level = :trace
        assert_equal :trace, logger.level
        assert_equal true, logger.debug?
        assert_equal true, logger.trace?
      end

      it 'return false for debug? with global :debug level' do
        SemanticLogger.default_level = :debug
        assert_equal :debug, logger.level, logger.inspect
        assert_equal true, logger.debug?, logger.inspect
        assert_equal false, logger.trace?, logger.inspect
      end

      it 'return true for debug? with global :info level' do
        SemanticLogger.default_level = :info
        assert_equal :info, logger.level, logger.inspect
        assert_equal false, logger.debug?, logger.inspect
        assert_equal false, logger.trace?, logger.inspect
      end

      it 'return false for debug? with instance :debug level' do
        logger.level = :debug
        assert_equal :debug, logger.level, logger.inspect
        assert_equal true, logger.debug?, logger.inspect
        assert_equal false, logger.trace?, logger.inspect
      end

      it 'return true for debug? with instance :info level' do
        logger.level = :info
        assert_equal :info, logger.level, logger.inspect
        assert_equal false, logger.debug?, logger.inspect
        assert_equal false, logger.trace?, logger.inspect
      end
    end

    describe '.tagged' do
      it 'sets global defaults' do
        assert_equal [], SemanticLogger.tags
        assert_equal 0, SemanticLogger.backtrace_level_index
      end

      it 'add tags to log entries' do
        logger.tagged('12345', 'DJHSFK') do
          logger.info('hello world')

          assert log = log_message
          assert_equal 'hello world', log.message
          assert_equal %w[12345 DJHSFK], log.tags
        end
      end

      it 'add embedded tags to log entries' do
        logger.tagged('First Level', 'tags') do
          logger.tagged('Second Level') do
            assert_equal ['First Level', 'tags', 'Second Level'], logger.tags
            logger.info('hello world')

            assert log = log_message
            assert_equal 'hello world', log.message
            assert_equal ['First Level', 'tags', 'Second Level'], log.tags
          end
          assert_equal ['First Level', 'tags'], logger.tags
        end
      end

      it 'also supports named tagging' do
        logger.tagged(level1: 1) do
          assert_equal({level1: 1}, SemanticLogger.named_tags)
          logger.tagged(level2: 2, more: 'data') do
            assert_equal({level1: 1, level2: 2, more: 'data'}, SemanticLogger.named_tags)
            logger.tagged(level3: 3) do
              assert_equal({level1: 1, level2: 2, more: 'data', level3: 3}, SemanticLogger.named_tags)
            end
          end
        end
      end

      it 'is compatible with rails logging that uses arrays and nils' do
        logger.tagged('', %w[12345 DJHSFK], nil) do
          logger.info('hello world')

          assert log = log_message
          assert_equal 'hello world', log.message
          assert_equal %w[12345 DJHSFK], log.tags
        end
      end
    end
  end
end
