require_relative 'test_helper'

class SemanticLoggerTest < Minitest::Test
  describe SemanticLogger do
    describe '.add_appender' do
      before do
        @appender = nil
      end

      after do
        SemanticLogger.remove_appender(@appender)
        File.delete('sample.log') if File.exist?('sample.log')
      end

      it 'adds file appender' do
        @appender = SemanticLogger.add_appender(file_name: 'sample.log')
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
        assert @appender.formatter.is_a?(SemanticLogger::Formatters::Default)
      end

      it 'adds file appender with json format' do
        @appender = SemanticLogger.add_appender(file_name: 'sample.log', formatter: :json)
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
        assert @appender.formatter.is_a?(SemanticLogger::Formatters::Json)
      end

      it 'adds stream appender' do
        @appender = SemanticLogger.add_appender(io: STDOUT)
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'adds symbol appender' do
        @appender = SemanticLogger.add_appender(appender: :wrapper, logger: Logger.new(STDOUT))
        assert @appender.is_a?(SemanticLogger::Appender::Wrapper), @appender.ai
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'adds logger wrapper appender' do
        @appender = SemanticLogger.add_appender(logger: ::Logger.new(STDOUT))
        assert @appender.is_a?(SemanticLogger::Appender::Wrapper)
        assert @appender.logger.is_a?(::Logger)
        assert SemanticLogger.appenders.include?(@appender)
        assert @appender.formatter.is_a?(SemanticLogger::Formatters::Default)
      end

      it 'adds logger wrapper appender with color formatter' do
        @appender = SemanticLogger.add_appender(logger: ::Logger.new(STDOUT), formatter: :color)
        assert @appender.is_a?(SemanticLogger::Appender::Wrapper)
        assert @appender.logger.is_a?(::Logger)
        assert SemanticLogger.appenders.include?(@appender)
        assert @appender.formatter.is_a?(SemanticLogger::Formatters::Color)
      end

      it 'adds appender' do
        @appender = SemanticLogger.add_appender(appender: SemanticLogger::Appender::File.new(io: STDOUT))
        assert @appender.is_a?(SemanticLogger::Appender::File), @appender.ai
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'fails to add invalid logger appender' do
        assert_raises do
          SemanticLogger.add_appender(logger: 'blah')
        end
      end
    end

    describe '.add_appender DEPRECATED' do
      before do
        @appender = nil
      end

      after do
        SemanticLogger.remove_appender(@appender) if @appender
        File.delete('sample.log') if File.exist?('sample.log')
      end

      it 'adds file appender' do
        @appender = SemanticLogger.add_appender('sample.log')
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'adds stream appender' do
        @appender = SemanticLogger.add_appender(STDOUT)
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'adds appender' do
        @appender = SemanticLogger.add_appender(SemanticLogger::Appender::File.new(io: STDOUT))
        assert @appender.is_a?(SemanticLogger::Appender::File), @appender.ai
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'adds logger wrapper appender' do
        @appender = SemanticLogger.add_appender(::Logger.new(STDOUT))
        assert @appender.is_a?(SemanticLogger::Appender::Wrapper)
        assert @appender.logger.is_a?(::Logger)
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'fails to add invalid logger appender' do
        assert_raises do
          SemanticLogger.add_appender(logger: 'blah')
        end
      end
    end

    describe 'mock_logger' do
      before do
        # Use a mock logger that just keeps the last logged entry in an instance
        # variable
        SemanticLogger.default_level   = :trace
        SemanticLogger.backtrace_level = nil
        @mock_logger                   = MockLogger.new
        @appender                      = SemanticLogger.add_appender(logger: @mock_logger)

        # Use this test's class name as the application name in the log output
        @logger                        = SemanticLogger['LoggerTest']
        @hash                          = {session_id: 'HSSKLEU@JDK767', tracking_number: 12345}
        @hash_str                      = @hash.inspect.sub("{", "\\{").sub("}", "\\}")
        @thread_name                   = Thread.current.name
      end

      after do
        SemanticLogger.remove_appender(@appender)
      end

      describe '.tagged' do
        it 'add tags to log entries' do
          SemanticLogger.tagged('12345', 'DJHSFK') do
            @logger.info('Hello world')
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{@thread_name}\] \[12345\] \[DJHSFK\] LoggerTest -- Hello world/, @mock_logger.message)
          end
        end

        it 'add embedded tags to log entries' do
          SemanticLogger.tagged('First Level', 'tags') do
            SemanticLogger.tagged('Second Level') do
              @logger.info('Hello world')
              SemanticLogger.flush
              assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{@thread_name}\] \[First Level\] \[tags\] \[Second Level\] LoggerTest -- Hello world/, @mock_logger.message)
            end
            assert_equal 2, SemanticLogger.tags.count, SemanticLogger.tags
            assert_equal 'First Level', SemanticLogger.tags.first
            assert_equal 'tags', SemanticLogger.tags.last
          end
        end
      end

      describe '.named_tagged' do
        it 'logs named tags' do
          SemanticLogger.named_tagged(tracking_number: '123456') do
            SemanticLogger.named_tagged(even: 2, more: 'data') do
              @logger.info('Hello world')
              SemanticLogger.flush
              assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{@thread_name}\] \[even: 2\] \[more: data\] \[tracking_number: 123456\] LoggerTest -- Hello world/, @mock_logger.message)
            end
          end
        end
      end

      describe '.fast_tag' do
        it 'add string tag to log entries' do
          @logger.fast_tag('12345') do
            @logger.info('Hello world')
            SemanticLogger.flush
            assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ I \[\d+:#{@thread_name}\] \[12345\] LoggerTest -- Hello world/, @mock_logger.message)
          end
        end
      end

      describe '.default_level' do
        before do
          SemanticLogger.default_level = :debug
        end

        it 'not log at a level below the global default' do
          assert_equal :debug, SemanticLogger.default_level
          assert_equal :debug, @logger.level
          @logger.trace('hello world', @hash) { 'Calculations' }
          SemanticLogger.flush
          assert_nil @mock_logger.message
        end

        it 'log at the instance level' do
          assert_equal :debug, SemanticLogger.default_level
          @logger.level = :trace
          assert_equal :trace, @logger.level
          @logger.trace('hello world', @hash) { 'Calculations' }
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ T \[\d+:#{@thread_name}\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message)
        end

        it 'not log at a level below the instance level' do
          assert_equal :debug, SemanticLogger.default_level
          @logger.level = :warn
          assert_equal :warn, @logger.level
          @logger.debug('hello world', @hash) { 'Calculations' }
          SemanticLogger.flush
          assert_nil @mock_logger.message
        end
      end

      describe '.silence' do
        before do
          SemanticLogger.default_level = :info
        end

        it 'not log at a level below the silence level' do
          assert_equal :info, SemanticLogger.default_level
          assert_equal :info, @logger.level
          @logger.silence do
            @logger.warn('hello world', @hash) { 'Calculations' }
            @logger.info('hello world', @hash) { 'Calculations' }
            @logger.debug('hello world', @hash) { 'Calculations' }
            @logger.trace('hello world', @hash) { 'Calculations' }
          end
          SemanticLogger.flush
          assert_nil @mock_logger.message
        end

        it 'log at the instance level even with the silencer at a higher level' do
          @logger.level = :trace
          assert_equal :trace, @logger.level
          @logger.silence do
            @logger.trace('hello world', @hash) { 'Calculations' }
          end
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ T \[\d+:#{@thread_name}\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message)
        end

        it 'log at a silence level below the default level' do
          assert_equal :info, SemanticLogger.default_level
          assert_equal :info, @logger.level
          @logger.silence(:debug) do
            @logger.debug('hello world', @hash) { 'Calculations' }
          end
          SemanticLogger.flush
          assert_match(/\d+-\d+-\d+ \d+:\d+:\d+.\d+ D \[\d+:#{@thread_name}\] LoggerTest -- hello world -- Calculations -- #{@hash_str}/, @mock_logger.message)
        end
      end

    end

  end
end
