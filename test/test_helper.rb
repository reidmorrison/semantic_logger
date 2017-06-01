# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

# Configure Rails Environment
ENV['RAILS_ENV'] = 'test'

require 'minitest/autorun'
require 'minitest/reporters'
require 'minitest/stub_any_instance'
require 'semantic_logger'
require 'logger'
require_relative 'mock_logger'
require 'awesome_print'

#Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
class Minitest::Test
  # Use AwesomePrint to display diffs
  define_method :mu_pp, &:awesome_inspect

  # Ensures that all elements in source are in target with the same value
  def assert_compare_hash(source, target)
    source.each_pair do |key, value|
      new_value = target[key]
      if value.nil?
        assert_nil new_value, "#{key} => #{new_value} when it supposed to be #{value}"
      else
        assert_equal value, new_value, "#{key} => #{new_value} when it supposed to be #{value}"
      end
    end
  end

end
