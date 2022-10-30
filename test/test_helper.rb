# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + "/../lib"

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
require "amazing_print"

# Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
class Minitest::Test
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

SemanticLogger.default_level   = :trace
SemanticLogger.backtrace_level = :trace
SemanticLogger.add_appender(file_name: "test.log", formatter: :color)

reporters = [
  Minitest::Reporters::ProgressReporter.new,
  SemanticLogger::Reporters::Minitest.new
]
Minitest::Reporters.use!(reporters)
