lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

# Maintain your gem's version:
require 'semantic_logger/version'

# Describe your gem and declare its dependencies:
Gem::Specification.new do |spec|
  spec.name                  = 'semantic_logger'
  spec.version               = SemanticLogger::VERSION
  spec.platform              = Gem::Platform::RUBY
  spec.authors               = ['Reid Morrison']
  spec.email                 = ['reidmo@gmail.com']
  spec.homepage              = 'https://github.com/rocketjob/semantic_logger'
  spec.summary               = 'Feature rich logging framework, and replacement for existing Ruby & Rails loggers.'
  spec.files                 = Dir['lib/**/*', 'LICENSE.txt', 'Rakefile', 'README.md']
  spec.license               = 'Apache-2.0'
  spec.required_ruby_version = '>= 2.3'
  spec.add_dependency 'concurrent-ruby', '~> 1.0'
end
