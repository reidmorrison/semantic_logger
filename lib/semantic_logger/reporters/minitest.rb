module SemanticLogger
  module Reporters
    # When using Minitest to run tests, log start and end messages for every test to the log file.
    # On completion the time it took to run the test is also logged.
    #
    # For example, add the following lines to `test_helper.rb`:
    #   reporters = [
    #     Minitest::Reporters::ProgressReporter.new,
    #     SemanticLogger::Reporters::Minitest.new
    #   ]
    #   Minitest::Reporters.use!(reporters)
    #
    # Log entries similar to the following should show up in the log file:
    #
    # 2019-01-30 14:41:21.590383 I [9989:70268303433760] (9.958ms) Minitest -- Passed: test_0002_infinite timeout
    # 2019-01-30 14:41:21.590951 I [9989:70268303433760] Minitest -- Started: test_0002_must return the servers in the supplied order
    # 2019-01-30 14:41:21.592012 I [9989:70268303433760] (1.019ms) Minitest -- Passed: test_0002_must return the servers in the supplied order
    # 2019-01-30 14:41:21.592054 I [9989:70268303433760] Minitest -- Started: test_0003_must handle an empty list of servers
    # 2019-01-30 14:41:21.592094 I [9989:70268303433760] (0.014ms) Minitest -- Passed: test_0003_must handle an empty list of servers
    # 2019-01-30 14:41:21.592118 I [9989:70268303433760] Minitest -- Started: test_0001_must return one server, once
    # 2019-01-30 14:41:21.592510 I [9989:70268303433760] (0.361ms) Minitest -- Passed: test_0001_must return one server, once
    #
    # Note:
    # - To use `Minitest::Reporters::ProgressReporter` the gem `minitest-reporters` is required, as well as the
    #   following line in `test_helper.rb`:
    #     `require 'minitest/reporters'`
    class Minitest < ::Minitest::AbstractReporter
      include SemanticLogger::Loggable

      logger.name = 'Minitest'

      attr_accessor :io

      def before_test(test)
        logger.info('START', name: test.name)
      end

      def after_test(test)
        if test.error?
          logger.benchmark_error('FAIL', payload: {name: test.name}, duration: test.time * 1_000, metric: 'minitest/fail')
        elsif test.skipped?
          logger.benchmark_warn('SKIP', payload: {name: test.name}, duration: test.time * 1_000, metric: 'minitest/skip')
        else
          logger.benchmark_info('PASS', payload: {name: test.name}, duration: test.time * 1_000, metric: 'minitest/pass')
        end
      end
    end
  end
end
