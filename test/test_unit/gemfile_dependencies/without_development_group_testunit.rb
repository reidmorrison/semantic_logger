# frozen_string_literal: true

# Use Minitest as a canary gem to ensure that items moved to the :development
# group aren't required by the rest of the library, and are only for development
# or testing. As a result, it uses the Test::Unit library to ensure we're not
# pulling in Minitest.

# Allow pulling gems like Test::Unit from the Ruby Standard Library even if
# running inside a bundle due to `bundle exec`.
require "bundler"
Bundler.reset!

require "test/unit"

Test::Unit.at_start do
  # self.remove_const(MiniTest) if defined? MiniTest
  # self.remove_const(Minitest) if defined? Minitest

  # Pull in only the default gems.
  Bundler.reset!
  Bundler.require :default
end

# Ensure that we reset bundler so as not to interfere with the Minitest runners
# or other require statements outside this individual suite of tests.
Test::Unit.at_exit do
  Bundler.reset!
  Bundler.require :default, :development
  raise unless defined?(MiniTest) && defined?(Minitest)
end

class WithoutDevelopmentGroupGems < Test::Unit::TestCase
  def test_1_minitest_constants_are_undefined
    refute defined?(MiniTest), "minitest loaded from :development group"
    refute defined?(Minitest), "minitest loaded from :development group"
  end

  def test_2_logger_succeeds_without_development_gems
    msg = "test without :development gems"
    logger = SemanticLogger::Test::CaptureLogEvents.new
    logger.info msg
    assert_equal msg, logger.instance_variable_get(:@events).pop.message
  end
end
