require_relative 'test_helper'

class DebugAsTraceLoggerTest < Minitest::Test
  describe SemanticLogger::Logger do
    describe '.level?' do
      let :logger do
        SemanticLogger::DebugAsTraceLogger.new('TestLogger')
      end

      it 'return true for debug? with :trace level' do
        SemanticLogger.default_level = :trace
        assert_equal :trace, logger.level
        assert_equal true, logger.debug?
        assert_equal true, logger.trace?
      end

      it 'return false for debug? with global :debug level' do
        SemanticLogger.default_level = :debug
        assert_equal :debug, logger.level, logger
        assert logger.info?, logger.inspect
        refute logger.debug?, logger.inspect
        refute logger.trace?, logger.inspect
      end

      it 'return true for debug? with global :info level' do
        SemanticLogger.default_level = :info
        assert_equal :info, logger.level, logger.inspect
        refute logger.debug?, logger.inspect
        refute logger.trace?, logger.inspect
      end

      it 'return false for debug? with instance :debug level' do
        logger.level = :debug
        assert_equal :debug, logger.level, logger.inspect
        refute logger.debug?, logger.inspect
        refute logger.trace?, logger.inspect
      end

      it 'return true for debug? with instance :info level' do
        logger.level = :info
        assert_equal :info, logger.level, logger.inspect
        refute logger.debug?, logger.inspect
        refute logger.trace?, logger.inspect
      end
    end

    describe 'log' do
      include InMemoryAppenderHelper

      let :logger do
        SemanticLogger::DebugAsTraceLogger.new('TestLogger')
      end

      it 'not log trace when level is debug' do
        logger.level = :debug
        logger.trace('hello world', payload) { 'Calculations' }
        refute log_message
      end

      it 'not log debug when level is debug' do
        logger.level = :debug
        logger.debug('hello world', payload) { 'Calculations' }
        refute log_message
      end

      it 'map debug to trace' do
        logger.level = :trace
        logger.debug('hello world')
        assert log = log_message
        assert_equal :trace, log.level
      end

      it 'log trace as trace' do
        logger.level = :trace
        logger.trace('hello world', payload) { 'Calculations' }
        assert log = log_message
        assert_equal :trace, log.level
      end
    end
  end
end
