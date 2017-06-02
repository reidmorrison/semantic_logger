require_relative '../test_helper'

class TestLogger < Minitest::Test
  describe SemanticLogger::Logger do
    include InMemoryAppenderHelper

    it '#add' do
      logger.add(Logger::INFO, 'hello world', 'progname') { 'Data' }

      assert log = log_message
      assert_equal 'hello world -- progname -- Data', log.message
      assert_equal :info, log.level
    end

    it '#log' do
      logger.log(Logger::FATAL, 'hello world', 'progname') { 'Data' }

      assert log = log_message
      assert_equal 'hello world -- progname -- Data', log.message
      assert_equal :fatal, log.level
    end

    it '#unknown' do
      logger.unknown('hello world') { 'Data' }

      assert log = log_message
      assert_equal 'hello world -- Data', log.message
      assert_equal :error, log.level
      assert_equal 'TestLogger', log.name
    end

    it '#unknown? as error?' do
      SemanticLogger.default_level = :error
      assert logger.unknown?
      logger.log(Logger::UNKNOWN, 'hello world', 'progname') { 'Data' }

      assert log = log_message
      assert_equal 'hello world -- progname -- Data', log.message
      assert_equal :error, log.level
    end

    it '#unknown? as error? when false' do
      SemanticLogger.default_level = :fatal
      refute logger.unknown?
      logger.log(Logger::UNKNOWN, 'hello world', 'progname') { 'Data' }

      refute log_message
    end

    it '#silence_logger' do
      logger.silence_logger do
        logger.info 'hello world'
      end
      refute log_message
    end

    it '#<< as info' do
      logger << 'hello world'

      assert log = log_message
      assert_equal 'hello world', log.message
      assert_equal :info, log.level
    end

    it '#progname= as #name=' do
      assert_equal 'TestLogger', logger.name
      logger.progname = 'NewTest'
      assert_equal 'NewTest', logger.name
    end

    it '#progname as #name' do
      assert_equal 'TestLogger', logger.name
      assert_equal 'TestLogger', logger.progname
    end

    it '#sev_threshold= as #level=' do
      assert_equal :trace, logger.level
      logger.sev_threshold = Logger::DEBUG
      assert_equal :debug, logger.level
    end

    it '#sev_threshold as #level' do
      assert_equal :trace, logger.level
      assert_equal :trace, logger.sev_threshold
    end

    it '#formatter NOOP' do
      assert_nil logger.formatter
      logger.formatter = 'blah'
      assert_equal 'blah', logger.formatter
    end

    it '#datetime_format NOOP' do
      assert_nil logger.datetime_format
      logger.datetime_format = 'blah'
      assert_equal 'blah', logger.datetime_format
    end

    it '#close NOOP' do
      logger.close
      logger.info('hello world')

      assert log = log_message
      assert_equal 'hello world', log.message
      assert_equal :info, log.level
    end

    it '#reopen NOOP' do
      logger.reopen
      logger.info('hello world')

      assert log = log_message
      assert_equal 'hello world', log.message
      assert_equal :info, log.level
    end

  end
end
