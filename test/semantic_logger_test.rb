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
        assert @appender.formatter.is_a?(SemanticLogger::Formatters::Json), @appender.formatter.inspect
      end

      it 'adds stream appender' do
        @appender = SemanticLogger.add_appender(io: STDOUT)
        assert @appender.is_a?(SemanticLogger::Appender::File)
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'adds symbol appender' do
        @appender = SemanticLogger.add_appender(appender: :wrapper, logger: Logger.new(STDOUT))
        assert @appender.is_a?(SemanticLogger::Appender::Wrapper), -> { @appender.ai }
        assert SemanticLogger.appenders.include?(@appender)
      end

      it 'adds symbol appender with underscores' do
        @appender = SemanticLogger.add_appender(appender: :new_relic)
        assert @appender.is_a?(SemanticLogger::Appender::NewRelic), -> { @appender.ai }
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
      include InMemoryAppenderHelper

      describe '.tagged' do
        it 'add tags to log entries' do
          SemanticLogger.tagged('12345', 'DJHSFK') do
            logger.info('Hello world')

            assert log = log_message
            assert_equal %w[12345 DJHSFK], log.tags
          end
        end

        it 'add embedded tags to log entries' do
          SemanticLogger.tagged('First Level', 'tags') do
            SemanticLogger.tagged('Second Level') do
              logger.info('Hello world')

              assert log = log_message
              assert_equal ['First Level', 'tags', 'Second Level'], log.tags
            end
            assert_equal 2, SemanticLogger.tags.count, SemanticLogger.tags
            assert_equal 'First Level', SemanticLogger.tags.first
            assert_equal 'tags', SemanticLogger.tags.last
          end
        end

        it 'also supports named tagging' do
          SemanticLogger.tagged(level1: 1) do
            assert_equal({level1: 1}, SemanticLogger.named_tags)
            SemanticLogger.tagged(level2: 2, more: 'data') do
              assert_equal({level1: 1, level2: 2, more: 'data'}, SemanticLogger.named_tags)
              SemanticLogger.tagged(level3: 3) do
                assert_equal({level1: 1, level2: 2, more: 'data', level3: 3}, SemanticLogger.named_tags)
              end
            end
          end
        end
      end

      describe '.named_tags' do
        it 'returns named tags in creation order' do
          SemanticLogger.named_tagged(level1: 1) do
            assert_equal({level1: 1}, SemanticLogger.named_tags)
            SemanticLogger.named_tagged(level2: 2, more: 'data') do
              assert_equal({level1: 1, level2: 2, more: 'data'}, SemanticLogger.named_tags)
              SemanticLogger.named_tagged(level3: 3) do
                assert_equal({level1: 1, level2: 2, more: 'data', level3: 3}, SemanticLogger.named_tags)
              end
            end
          end
        end
      end

      describe '.named_tagged' do
        it 'logs named tags in creation order' do
          SemanticLogger.named_tagged(level1: 1) do
            SemanticLogger.named_tagged(level2: 2, more: 'data') do
              SemanticLogger.named_tagged(level3: 3) do
                logger.info('Hello world')

                assert log = log_message
                assert_equal({level1: 1, level2: 2, more: 'data', level3: 3}, log.named_tags)
              end
            end
          end
        end
      end

      describe '.fast_tag' do
        it 'add string tag to log entries' do
          logger.fast_tag('12345') do
            logger.info('Hello world')

            assert log = log_message
            assert_equal %w[12345], log.tags
          end
        end
      end

      describe '.default_level' do
        before do
          SemanticLogger.default_level = :debug
        end

        it 'not log at a level below the global default' do
          assert_equal :debug, SemanticLogger.default_level
          assert_equal :debug, logger.level
          logger.trace('hello world')

          refute log_message
        end

        it 'log at the instance level' do
          assert_equal :debug, SemanticLogger.default_level
          logger.level = :trace
          assert_equal :trace, logger.level
          logger.trace('hello world')

          assert log = log_message
          assert_equal :trace, log.level
          assert_equal 'hello world', log.message
        end

        it 'not log at a level below the instance level' do
          assert_equal :debug, SemanticLogger.default_level
          logger.level = :warn
          assert_equal :warn, logger.level
          logger.debug('hello world')

          refute log_message
        end
      end

      describe '.silence' do
        before do
          SemanticLogger.default_level = :info
        end

        it 'not log at a level below the silence level' do
          assert_equal :info, SemanticLogger.default_level
          assert_equal :info, logger.level
          logger.silence do
            logger.warn('hello world')
            logger.info('hello world')
            logger.debug('hello world')
            logger.trace('hello world')
          end

          refute log_message
        end

        it 'log at the instance level even with the silencer at a higher level' do
          logger.level = :trace
          assert_equal :trace, logger.level
          logger.silence do
            logger.trace('hello world')
          end

          assert log = log_message
          assert_equal :trace, log.level
          assert_equal 'hello world', log.message
        end

        it 'log at a silence level below the default level' do
          assert_equal :info, SemanticLogger.default_level
          assert_equal :info, logger.level
          logger.silence(:debug) do
            logger.debug('hello world')
          end

          assert log = log_message
          assert_equal :debug, log.level
          assert_equal 'hello world', log.message
        end
      end

      describe '.on_log' do
        before do
          SemanticLogger.default_level = :info
        end

        after do
          SemanticLogger::Processor.instance.appender.log_subscribers = nil
        end

        it 'registers a log listener' do
          SemanticLogger.on_log do |log|
            log.set_context(:custom_info, 'test')
          end

          assert_equal :info, SemanticLogger.default_level
          assert_equal :info, logger.level
          logger.silence(:debug) do
            logger.debug('hello world')
          end

          assert log = log_message
          assert_equal :debug, log.level
          assert_equal 'hello world', log.message
          assert_equal 'test', log.context[:custom_info]
        end
      end
    end
  end
end
