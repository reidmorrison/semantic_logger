require_relative "test_helper"
require "json"

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

        it "raises when the symbol resolves to a constant that is not a class" do
          SemanticLogger::Utils.const_set(:NotAClass, 42)
          error = assert_raises ArgumentError do
            SemanticLogger::Utils.constantize_symbol(:not_a_class, "SemanticLogger::Utils")
          end
          assert_match(/is not a class/, error.message)
        ensure
          SemanticLogger::Utils.send(:remove_const, :NotAClass)
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

      describe ".to_json" do
        # A binary string holding a byte (0xE2) that is not valid UTF-8.
        let(:binary_string) { "Bad: \xE2".b }

        it "serializes valid data directly" do
          assert_equal '{"a":1,"b":"x"}', SemanticLogger::Utils.to_json({a: 1, b: "x"})
        end

        it "repairs and serializes non UTF-8 data without raising" do
          result = SemanticLogger::Utils.to_json(
            {message: binary_string, list: [binary_string], "k\xE2".b => binary_string}
          )

          assert_equal({"message" => "Bad: ", "list" => ["Bad: "], "k" => "Bad: "}, JSON.parse(result))
        end

        it "only cleanses on failure, leaving valid strings identical" do
          # The cleansing fallback drops invalid bytes; a direct serialization keeps
          # everything. A multibyte UTF-8 string proves no lossy round-trip occurred.
          assert_equal '"€ café"', SemanticLogger::Utils.to_json("€ café")
        end

        it "re-raises errors that cleansing cannot fix" do
          # NaN is not representable in JSON and is unrelated to encoding, so the
          # retry after cleansing must still raise rather than swallow it.
          assert_raises(JSON::GeneratorError) do
            SemanticLogger::Utils.to_json({value: Float::NAN})
          end
        end
      end

      describe ".encode_utf8" do
        # A binary string holding a byte (0xE2) that is not valid UTF-8.
        # This is the exact failure mode reported in issue #180.
        let(:binary_string) { "Bad: \xE2".b }

        # A string tagged as UTF-8 but containing an invalid byte sequence.
        let(:invalid_utf8) { (+"Bad: \xE2").force_encoding(Encoding::UTF_8) }

        it "returns a valid UTF-8 string unchanged" do
          string = "Héllo"
          result = SemanticLogger::Utils.encode_utf8(string)

          assert_same string, result
          assert_predicate result, :valid_encoding?
        end

        it "drops invalid bytes from a binary string" do
          result = SemanticLogger::Utils.encode_utf8(binary_string)

          assert_equal "Bad: ", result
          assert_equal Encoding::UTF_8, result.encoding
          assert_predicate result, :valid_encoding?
        end

        it "scrubs an invalid UTF-8 string" do
          result = SemanticLogger::Utils.encode_utf8(invalid_utf8)

          assert_equal "Bad: ", result
          assert_equal Encoding::UTF_8, result.encoding
          assert_predicate result, :valid_encoding?
        end

        it "transcodes a non UTF-8 encoding, preserving representable characters" do
          result = SemanticLogger::Utils.encode_utf8("café".encode(Encoding::ISO_8859_1))

          assert_equal "café", result
          assert_equal Encoding::UTF_8, result.encoding
        end

        it "produces a string that can be serialized to JSON" do
          result = SemanticLogger::Utils.encode_utf8(binary_string)

          assert_equal '"Bad: "', result.to_json
        end

        it "recurses through nested hashes, cleansing keys and values" do
          result = SemanticLogger::Utils.encode_utf8(
            binary_string => {"inner\xE2".b => binary_string}
          )

          assert_equal({"Bad: " => {"inner" => "Bad: "}}, result)

          all_strings = result.flat_map { |key, value| [key, *value.keys, *value.values] }

          all_strings.each { |string| assert_predicate string, :valid_encoding? }
        end

        it "recurses through arrays" do
          result = SemanticLogger::Utils.encode_utf8([binary_string, ["nested\xE2".b]])

          assert_equal ["Bad: ", ["nested"]], result
        end

        it "leaves non-string scalars untouched" do
          assert_equal 42, SemanticLogger::Utils.encode_utf8(42)
          assert_equal :sym, SemanticLogger::Utils.encode_utf8(:sym)
          assert_nil SemanticLogger::Utils.encode_utf8(nil)
        end
      end
    end
  end
end
