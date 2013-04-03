lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

require 'rubygems'
require 'rubygems/package'
require 'rake/clean'
require 'rake/testtask'
require 'date'
require 'semantic_logger/version'

desc "Build gem"
task :gem  do |t|
  gemspec = Gem::Specification.new do |spec|
    spec.name        = 'semantic_logger'
    spec.version     = SemanticLogger::VERSION
    spec.platform    = Gem::Platform::RUBY
    spec.authors     = ['Reid Morrison']
    spec.email       = ['reidmo@gmail.com']
    spec.homepage    = 'https://github.com/ClarityServices/semantic_logger'
    spec.date        = Date.today.to_s
    spec.summary     = "Improved logging for Ruby"
    spec.description = "Semantic Logger takes logging in Ruby to a new level by adding several new capabilities to the commonly used Logging API"
    spec.files       = FileList["./**/*"].exclude(/\.gem$/, /\.log$/,/nbproject/).map{|f| f.sub(/^\.\//, '')}
    spec.license     = "Apache License V2.0"
    spec.has_rdoc    = true
    spec.add_dependency 'sync_attr', '>= 1.0'
    spec.add_dependency 'thread_safe', '>= 0.1.0'
  end
  Gem::Package.build gemspec
end

desc "Run Test Suite"
task :test do
  Rake::TestTask.new(:functional) do |t|
    t.test_files = FileList['test/*_test.rb']
    t.verbose    = true
  end

  Rake::Task['functional'].invoke
end
