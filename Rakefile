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

desc "Run only test/unit tests"
task :test_unit, [:options] do |t, args|
  args.with_defaults options: nil
  options = args.to_a
  options << '--verbose' if ENV['TESTOPTS']
  options = options.compact.uniq.join ?\s
  FileList["test/**/*_testunit.rb"].map do |f|
    sh "ruby #{f} #{options}"
  end
  puts
end

Rake::TestTask.new do |t|
  t.description = "Run all tests"
  t.pattern = "test/**/*_test.rb"
  t.verbose = true
  t.warning = false
end

task :test => :test_unit
task default: :test
