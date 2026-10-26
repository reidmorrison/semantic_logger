require_relative "test_helper"

module SemanticLogger
  class LevelsTest < Minitest::Test
    describe Levels do
      describe ".index" do
        it "returns nil for nil" do
          assert_nil SemanticLogger::Levels.index(nil)
        end

        it "maps each symbol level to its index" do
          SemanticLogger::Levels::LEVELS.each_with_index do |level, index|
            assert_equal index, SemanticLogger::Levels.index(level)
          end
        end

        it "maps string levels" do
          assert_equal SemanticLogger::Levels::LEVELS.index(:info), SemanticLogger::Levels.index("info")
        end

        it "maps mixed case string levels" do
          assert_equal SemanticLogger::Levels::LEVELS.index(:warn), SemanticLogger::Levels.index("WARN")
        end

        it "maps integer ::Logger levels" do
          assert_equal SemanticLogger::Levels::LEVELS.index(:debug), SemanticLogger::Levels.index(::Logger::DEBUG)
          assert_equal SemanticLogger::Levels::LEVELS.index(:info),  SemanticLogger::Levels.index(::Logger::INFO)
          assert_equal SemanticLogger::Levels::LEVELS.index(:warn),  SemanticLogger::Levels.index(::Logger::WARN)
          assert_equal SemanticLogger::Levels::LEVELS.index(:error), SemanticLogger::Levels.index(::Logger::ERROR)
          assert_equal SemanticLogger::Levels::LEVELS.index(:fatal), SemanticLogger::Levels.index(::Logger::FATAL)
        end

        it "maps ::Logger::UNKNOWN to error" do
          assert_equal SemanticLogger::Levels::LEVELS.index(:error), SemanticLogger::Levels.index(::Logger::UNKNOWN)
        end

        it "raises for an invalid symbol" do
          assert_raises ArgumentError do
            SemanticLogger::Levels.index(:bogus)
          end
        end

        it "raises for an invalid string" do
          assert_raises ArgumentError do
            SemanticLogger::Levels.index("bogus")
          end
        end

        it "raises ArgumentError for an Integer too large to be an index" do
          assert_raises ArgumentError do
            SemanticLogger::Levels.index(2**70)
          end
        end
      end

      describe ".valid?" do
        it "accepts every level form that .index maps" do
          assert SemanticLogger::Levels.valid?(:warn)
          assert SemanticLogger::Levels.valid?("WARN")
          assert SemanticLogger::Levels.valid?(::Logger::WARN)
        end

        it "rejects anything else without raising" do
          [nil, :bogus, "bogus", 99, 2**70, -(2**70), 1.5, [], {}].each do |value|
            refute SemanticLogger::Levels.valid?(value), "expected #{value.inspect} to be invalid"
          end
        end
      end

      describe ".level" do
        it "returns the symbol for an index" do
          SemanticLogger::Levels::LEVELS.each_with_index do |level, index|
            assert_equal level, SemanticLogger::Levels.level(index)
          end
        end
      end
    end
  end
end
