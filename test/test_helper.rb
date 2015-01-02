# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

#require 'rubygems'
require 'minitest/autorun'
require 'minitest/reporters'
require 'minitest/stub_any_instance'
require 'shoulda/context'
require 'semantic_logger'
require 'logger'
require 'mock_logger'

Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new