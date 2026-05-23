require_relative "test_helper"

module SemanticLogger
  class LogTest < Minitest::Test
    describe Log do
      describe "cleansed_message" do
        [
          "\e[32m[SUCCESS] User profile updated successfully!\e[0m",
          "[SUCCESS] User profile updated successfully!",
          "\etest string \n",
          "test string",
          " test strip string \n",
          "test strip string"
        ].each_slice(2) do |(message, cleansed_message)|
          describe message.to_s do
            it "clears correctly" do
              log = SemanticLogger::Log.new("LogTest", :info)
              log.message = message

              assert_equal log.cleansed_message, cleansed_message
            end
          end
        end
      end
    end
  end
end
