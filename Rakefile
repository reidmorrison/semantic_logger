require "rake/clean"
require "rake/testtask"

$LOAD_PATH.unshift File.expand_path("lib", __dir__)
require "semantic_logger/version"

task :gem do
  system "gem build semantic_logger.gemspec"
end

task publish: :gem do
  system "git tag -a v#{SemanticLogger::VERSION} -m 'Tagging #{SemanticLogger::VERSION}'"
  system "git push --tags"
  system "gem push semantic_logger-#{SemanticLogger::VERSION}.gem"
  system "rm semantic_logger-#{SemanticLogger::VERSION}.gem"
end

Rake::TestTask.new(:test) do |t|
  t.pattern = "test/**/*_test.rb"
  t.verbose = true
  t.warning = false
end

task default: :test
