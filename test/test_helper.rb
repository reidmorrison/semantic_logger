# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift "#{File.dirname(__FILE__)}/../lib"

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require "minitest/autorun"
require "minitest/reporters"
require "minitest/stub_any_instance"
if ENV["LOGGER_SYNC"]
  require "semantic_logger/sync"
else
  require "semantic_logger"
end
require_relative "in_memory_appender"
require_relative "in_memory_batch_appender"
require_relative "in_memory_metrics_appender"
require_relative "in_memory_appender_helper"
require "amazing_print"

# Add Semantic Logger helpers for Minitest
Minitest::Test.include SemanticLogger::Test::Minitest

# Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
module Minitest
  class Test
    # Use AwesomePrint to display diffs
    define_method :mu_pp, &:awesome_inspect

    # Use AwesomePrint to display messages
    def message(msg = nil, ending = nil)
      proc {
        msg            = msg.call.chomp(".") if msg.is_a?(Proc)
        custom_message = "#{msg.ai}.\n" unless msg.nil? || msg.to_s.empty?
        "#{custom_message}#{yield}#{ending || '.'}"
      }
    end
  end
end

SemanticLogger.default_level   = :trace
SemanticLogger.backtrace_level = :trace
SemanticLogger.add_appender(file_name: "test.log", formatter: :color)

reporters = [
  Minitest::Reporters::ProgressReporter.new,
  SemanticLogger::Reporters::Minitest.new
]
Minitest::Reporters.use!(reporters)

def add_mocks_to_load_path
  $LOAD_PATH.unshift File.join(File.dirname(__FILE__), "mocks")
end
