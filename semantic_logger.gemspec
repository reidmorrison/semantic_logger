lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

# Maintain your gem's version:
require "semantic_logger/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |spec|
  spec.name                  = "semantic_logger"
  spec.version               = SemanticLogger::VERSION
  spec.platform              = Gem::Platform::RUBY
  spec.authors               = ["Reid Morrison"]
  spec.homepage              = "https://logger.rocketjob.io"
  spec.summary               = "Feature rich logging framework, and replacement for existing Ruby & Rails loggers."
  spec.files                 = Dir["lib/**/*", "LICENSE.txt", "Rakefile", "README.md"]
  spec.license               = "Apache-2.0"
  spec.required_ruby_version = ">= 2.5"
  spec.add_dependency "concurrent-ruby", "~> 1.0"

  spec.post_install_message = <<~'REXML'
    While this gem does not use REXML directly, Ruby >= 3.1.0 breaks without it
    because the Splunk SDK requires rexml/document for its xml_shim.rb. As rexml
    is no longer included as a default gem beyond Ruby 2.7.5, users of more
    recent Ruby versions may need to add the following to their Gemfile or
    GEM_HOME directory to run SemanticLogger:

        gem "rexml", "~> 3.2"

  REXML
end
