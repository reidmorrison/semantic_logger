$:.push File.expand_path("../lib", __FILE__)

# Maintain your gem's version:
require 'semantic_logger/version'

# Describe your gem and declare its dependencies:
Gem::Specification.new do |spec|
  spec.name        = 'semantic_logger'
  spec.version     = SemanticLogger::VERSION
  spec.platform    = Gem::Platform::RUBY
  spec.authors     = ['Reid Morrison']
  spec.email       = ['reidmo@gmail.com']
  spec.homepage    = 'https://github.com/ClarityServices/semantic_logger'
  spec.summary     = "Improved logging for Ruby"
  spec.description = "Semantic Logger takes logging in Ruby to a new level by adding several new capabilities to the commonly used Logging API"
  spec.files       = Dir["lib/**/*", "LICENSE.txt", "Rakefile", "README.md"]
  spec.test_files  = Dir["test/**/*"]
  spec.license     = "Apache License V2.0"
  spec.has_rdoc    = true
  spec.add_dependency 'sync_attr', '>= 1.0'
  spec.add_dependency 'thread_safe', '>= 0.1.0'
end
