lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

require 'rubygems'
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
    spec.summary     = "Semantic Logger for Ruby, and Ruby on Rails"
    spec.description = "Machine readable document oriented logging with support for MongoDB and text files"
    spec.files       = FileList["./**/*"].exclude('*.gem', 'nbproject').map{|f| f.sub(/^\.\//, '')}
    spec.has_rdoc    = true
    spec.add_dependency 'sync_attr'
    spec.add_dependency 'thread_safe'
    spec.add_development_dependency 'shoulda'
  end
  Gem::Builder.new(gemspec).build
end

desc "Run Test Suite"
task :test do
  Rake::TestTask.new(:functional) do |t|
    t.test_files = FileList['test/*_test.rb']
    t.verbose    = true
  end

  Rake::Task['functional'].invoke
end
