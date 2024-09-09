lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

# Maintain your gem's version:
require "semantic_logger/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name                  = "semantic_logger"
  s.version               = SemanticLogger::VERSION
  s.platform              = Gem::Platform::RUBY
  s.authors               = ["Reid Morrison"]
  s.homepage              = "https://logger.rocketjob.io"
  s.summary               = "Feature rich logging framework, and replacement for existing Ruby & Rails loggers."
  s.files                 = Dir["lib/**/*", "LICENSE.txt", "Rakefile", "README.md"]
  s.license               = "Apache-2.0"
  s.required_ruby_version = ">= 2.5"
  s.add_dependency "concurrent-ruby", "~> 1.0"
  s.metadata = {
    "bug_tracker_uri"       => "https://github.com/reidmorrison/semantic_logger/issues",
    "documentation_uri"     => "https://logger.rocketjob.io",
    "source_code_uri"       => "https://github.com/reidmorrison/semantic_logger/tree/v#{SemanticLogger::VERSION}",
    "rubygems_mfa_required" => "true"
  }
end
