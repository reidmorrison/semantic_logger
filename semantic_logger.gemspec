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
  s.summary               = "High-performance, asynchronous structured logging framework for Ruby & Rails."
  s.description           = "Semantic Logger is a high-performance, asynchronous structured logging framework for Ruby & Rails. " \
                            "It logs to multiple destinations via a background thread, preserving structured (semantic) payloads."
  s.files                 = Dir["lib/**/*", "LICENSE.txt", "Rakefile", "README.md"]
  s.license               = "Apache-2.0"
  s.required_ruby_version = ">= 3.2"
  s.add_dependency "concurrent-ruby", "~> 1.0"
  s.metadata = {
    "bug_tracker_uri"       => "https://github.com/reidmorrison/semantic_logger/issues",
    "changelog_uri"         => "https://github.com/reidmorrison/semantic_logger/releases",
    "documentation_uri"     => "https://logger.rocketjob.io",
    "source_code_uri"       => "https://github.com/reidmorrison/semantic_logger/tree/v#{SemanticLogger::VERSION}",
    "rubygems_mfa_required" => "true"
  }
end
