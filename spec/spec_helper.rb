require "semantic_logger"
require "semantic_logger/test/rspec"

# Run logging synchronously so events are captured on the calling thread.
SemanticLogger.sync!
SemanticLogger.default_level = :trace

RSpec.configure do |config|
  config.include SemanticLogger::Test::RSpec

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
