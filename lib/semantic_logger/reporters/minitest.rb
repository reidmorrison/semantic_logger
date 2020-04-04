module SemanticLogger
  module Reporters
    # When using Minitest to run tests, log start and end messages for every test to the log file.
    # On completion the time it took to run the test is also logged.
    #
    # For example, add the following lines to `test_helper.rb`:
    #   require 'minitest/reporters'
    #
    #   reporters = [
    #     Minitest::Reporters::ProgressReporter.new,
    #     SemanticLogger::Reporters::Minitest.new
    #   ]
    #   Minitest::Reporters.use!(reporters)
    #
    # And add `gem minitest-reporters` to the Gemfile.
    #
    # Log entries similar to the following should show up in the log file:
    #
    # 2019-02-06 18:58:17.522467 I [84730:70256441962000] Minitest -- START RocketJob::DirmonEntry::with valid entry::#archive_file test_0001_moves file to archive dir
    # 2019-02-06 18:58:17.527492 I [84730:70256441962000] (4.980ms) Minitest -- PASS RocketJob::DirmonEntry::with valid entry::#archive_file test_0001_moves file to archive dir
    # 2019-02-06 18:58:17.527835 I [84730:70256441962000] Minitest -- START RocketJob::DirmonEntry::#job_class::with a valid job_class_name test_0001_return job class
    # 2019-02-06 18:58:17.529761 I [84730:70256441962000] (1.882ms) Minitest -- PASS RocketJob::DirmonEntry::#job_class::with a valid job_class_name test_0001_return job class
    class Minitest < ::Minitest::AbstractReporter
      include SemanticLogger::Loggable

      logger.name = "Minitest"

      attr_accessor :io

      def before_test(test)
        logger.info("START #{test.class_name} #{test.name}")
      end

      def after_test(test)
        if test.error?
          logger.benchmark_error("FAIL #{test.class_name} #{test.name}", duration: test.time * 1_000, metric: "minitest/fail")
        elsif test.skipped?
          logger.benchmark_warn("SKIP #{test.class_name} #{test.name}", duration: test.time * 1_000, metric: "minitest/skip")
        else
          logger.benchmark_info("PASS #{test.class_name} #{test.name}", duration: test.time * 1_000, metric: "minitest/pass")
        end
      end
    end
  end
end
