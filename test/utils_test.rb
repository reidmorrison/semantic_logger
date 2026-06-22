require_relative "test_helper"

module SemanticLogger
  class UtilsTest < Minitest::Test
    describe Utils do
      describe ".constantize_symbol" do
        it "resolves a built-in appender symbol" do
          assert_equal SemanticLogger::Appender::File, SemanticLogger::Utils.constantize_symbol(:file)
        end

        it "resolves a symbol in a custom namespace" do
          assert_equal SemanticLogger::Formatters::Json,
                       SemanticLogger::Utils.constantize_symbol(:json, "SemanticLogger::Formatters")
        end

        it "raises a helpful error for an unknown symbol" do
          error = assert_raises ArgumentError do
            SemanticLogger::Utils.constantize_symbol(:does_not_exist)
          end
          assert_match(/Could not convert symbol/, error.message)
        end
      end

      describe ".camelize" do
        it "camelizes a simple term" do
          assert_equal "FooBar", SemanticLogger::Utils.camelize("foo_bar")
        end

        it "converts slashes to namespaces" do
          assert_equal "Foo::BarBaz", SemanticLogger::Utils.camelize("foo/bar_baz")
        end

        it "handles a single word" do
          assert_equal "Foo", SemanticLogger::Utils.camelize("foo")
        end
      end

      describe ".method_visibility" do
        let(:mod) do
          Module.new do
            def public_method
            end

            private

            def private_method
            end
          end
        end

        it "detects a public method" do
          assert_equal :public, SemanticLogger::Utils.method_visibility(mod, :public_method)
        end

        it "detects a private method" do
          assert_equal :private, SemanticLogger::Utils.method_visibility(mod, :private_method)
        end

        it "returns nil for an unknown method" do
          assert_nil SemanticLogger::Utils.method_visibility(mod, :missing_method)
        end

        it "accepts a string method name" do
          assert_equal :public, SemanticLogger::Utils.method_visibility(mod, "public_method")
        end
      end

      describe ".extract_path?" do
        it "is true for semantic logger paths" do
          assert SemanticLogger::Utils.extract_path?("/gems/foo/lib/semantic_logger/logger.rb:10")
        end

        it "is false for application paths" do
          refute SemanticLogger::Utils.extract_path?("/app/models/user.rb:10")
        end
      end

      describe ".extract_backtrace" do
        it "strips leading semantic logger entries" do
          stack = [
            "/gems/foo/lib/semantic_logger/logger.rb:10",
            "/gems/foo/lib/semantic_logger/base.rb:20",
            "/app/models/user.rb:30",
            "/gems/foo/lib/semantic_logger/log.rb:40"
          ]
          result = SemanticLogger::Utils.extract_backtrace(stack)
          assert_equal "/app/models/user.rb:30", result.first
          # Trailing semantic_logger entries are left in place.
          assert_includes result, "/gems/foo/lib/semantic_logger/log.rb:40"
        end
      end

      describe ".strip_path?" do
        it "is true for gem paths" do
          gem_path = "#{Gem.default_dir}/gems/foo/lib/foo.rb:10"
          assert SemanticLogger::Utils.strip_path?(gem_path)
        end

        it "is false for application paths" do
          refute SemanticLogger::Utils.strip_path?("/app/models/user.rb:10")
        end
      end
    end
  end
end
