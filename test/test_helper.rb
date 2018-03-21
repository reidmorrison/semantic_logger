# Allow test to be run in-place without requiring a gem install
$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

# Configure Rails Environment
ENV['RAILS_ENV'] = 'test'

require 'minitest/autorun'
require 'minitest/reporters'
require 'minitest/stub_any_instance'
require 'semantic_logger'
#require 'logger'
require_relative 'in_memory_appender'
require_relative 'in_memory_batch_appender'
require_relative 'in_memory_metrics_appender'
require_relative 'in_memory_appender_helper'
require 'awesome_print'

#Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
class Minitest::Test
  # Use AwesomePrint to display diffs
  define_method :mu_pp, &:awesome_inspect

  # Use AwesomePrint to display messages
  def message msg = nil, ending = nil, &default
    proc {
      msg            = msg.call.chomp(".") if Proc === msg
      custom_message = "#{msg.ai}.\n" unless msg.nil? or msg.to_s.empty?
      "#{custom_message}#{default.call}#{ending || "."}"
    }
  end

end
