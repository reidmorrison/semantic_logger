require_relative "test_helper"
require "json"
require "timeout"

module SemanticLogger
  class UtilsTest < Minitest::Test
    # A named Struct, so that the placeholder for one nested too deeply names its class.
    DeepNode = Struct.new(:child)

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

      describe ".parse_url" do
        it "returns the parsed url" do
          assert_equal "host", SemanticLogger::Utils.parse_url("https://user:pw@host:8443/path").host
        end

        it "raises without the url, which can hold a password, in the message or as the cause" do
          error = assert_raises(URI::InvalidURIError) do
            SemanticLogger::Utils.parse_url("https://user:pa ss@host", option: ":proxy_url", hint: "Hint.")
          end

          assert_equal "Invalid :proxy_url, it is not a valid URI. Hint.", error.message
          assert_nil error.cause
        end
      end

      describe ".parse_url with nil" do
        it "raises, rather than parsing an empty url" do
          error = assert_raises(URI::InvalidURIError) { SemanticLogger::Utils.parse_url(nil) }

          assert_equal "Invalid :url, it is not a valid URI.", error.message
        end
      end

      describe ".without_url_in_errors" do
        it "returns the result of the block" do
          assert_equal(42, SemanticLogger::Utils.without_url_in_errors { 42 })
        end

        it "raises an error of the same class, without the url in the message or as the cause" do
          error_class = Class.new(StandardError)
          error       = assert_raises(error_class) do
            SemanticLogger::Utils.without_url_in_errors(option: ":brokers", errors: [error_class]) do
              raise error_class, "bad broker: user:s3cr3t@host"
            end
          end

          assert_equal "Invalid :brokers, it is not a valid URI.", error.message
          assert_nil error.cause
        end

        it "leaves other errors alone" do
          assert_raises(ArgumentError) { SemanticLogger::Utils.without_url_in_errors { raise ArgumentError } }
        end
      end

      describe ".redacted_url" do
        it "keeps only the scheme, host, and a port that is not the default" do
          assert_equal "https://host:8443", SemanticLogger::Utils.redacted_url("https://user:pw@host:8443/t0ken?api_key=k")
          assert_equal "https://host", SemanticLogger::Utils.redacted_url("https://host:443/path")
          assert_equal "udp://host:514", SemanticLogger::Utils.redacted_url("udp://host:514")
        end

        it "shows nothing of an invalid url" do
          assert_equal "(invalid url)", SemanticLogger::Utils.redacted_url("https://user:pa ss@host")
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

        it "does not modify the supplied stack" do
          stack = ["/gems/foo/lib/semantic_logger/logger.rb:10", "/app/models/user.rb:30"]
          SemanticLogger::Utils.extract_backtrace(stack)

          assert_equal ["/gems/foo/lib/semantic_logger/logger.rb:10", "/app/models/user.rb:30"], stack
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

        it "writes an object whose own #to_json cannot serialize it as its #to_s" do
          broken = Object.new
          def broken.to_json(*) = raise(JSON::GeneratorError, "cannot serialize")
          def broken.to_s = "broken \xFF".b

          assert_equal '{"value":"broken "}', SemanticLogger::Utils.to_json({value: broken})
        end

        it "re-raises other errors from an object's own #to_json, which repairing cannot fix" do
          broken = Object.new
          def broken.to_json(*) = raise(ArgumentError, "bug in #to_json")

          assert_raises(ArgumentError) { SemanticLogger::Utils.to_json({value: broken}) }
        end

        it "serializes Infinity and NaN as strings" do
          result = SemanticLogger::Utils.to_json(
            {amount: "1e400".to_f, loss: -Float::INFINITY, ratio: Float::NAN, ok: 1.5}
          )

          assert_equal({"amount" => "Infinity", "loss" => "-Infinity", "ratio" => "NaN", "ok" => 1.5},
                       JSON.parse(result))
        end

        it "serializes a structure nested as deeply as JSON.parse accepts" do
          # A request body that JSON.parse accepts, logged inside the payload as
          # rails_semantic_logger logs request params, is nested past the generator limit.
          body   = "#{'{"a":' * 99}1#{'}' * 99}"
          result = SemanticLogger::Utils.to_json({payload: {params: JSON.parse(body)}})

          assert_kind_of Hash, JSON.parse(result)
        end

        it "serializes a structure that references itself" do
          looped = {name: "loop"}
          looped[:self] = looped

          assert_kind_of Hash, JSON.parse(SemanticLogger::Utils.to_json(looped))
        end

        it "replaces a structure nested too deeply with a placeholder naming its class" do
          nested = {"leaf" => 1}
          99.times { nested = {"a" => nested} }

          parsed = JSON.parse(SemanticLogger::Utils.to_json({payload: [nested]}))
          parsed = parsed["payload"].first
          29.times { parsed = parsed["a"] }

          assert_equal "#<Hash nested too deeply>", parsed["a"]
        end

        [2_000, 100_000].each do |depth|
          it "serializes a structure #{depth} levels deep without exhausting the stack" do
            # Built iteratively: a recursive walk of the full depth raises SystemStackError,
            # an Exception that would stop an async appender's worker thread.
            nested = 1
            depth.times { nested = [nested] }

            parsed = JSON.parse(SemanticLogger::Utils.to_json({payload: nested, amount: Float::NAN}))

            assert_equal "NaN", parsed["amount"]
            assert_includes JSON.generate(parsed["payload"], max_nesting: false), "#<Array nested too deeply>"
          end
        end

        it "does not reveal the instance variables of an object nested too deeply" do
          client = Class.new do
            def initialize
              @password = "secret"
            end
          end.new
          nested = [client]
          40.times { nested = [nested] }

          result = SemanticLogger::Utils.to_json({payload: nested, amount: Float::NAN})

          refute_includes result, "secret"
        end

        describe "Struct and Data" do
          let(:client) do
            Class.new do
              def initialize
                @password = "secret"
              end

              def to_s
                "#<Client>"
              end

              # Like any object without a #to_s of its own, whose #inspect lists its instance variables.
              def inspect
                "#<Client @password=\"secret\">"
              end
            end.new
          end

          it "serializes a Struct as an object of its members" do
            point = Struct.new(:x, :y).new(1, "two")

            assert_equal '{"point":{"x":1,"y":"two"}}', SemanticLogger::Utils.to_json({point: point})
          end

          it "serializes a Data instance as an object of its members" do
            point = Data.define(:x, :y).new(x: 1, y: "two")

            assert_equal '{"point":{"x":1,"y":"two"}}', SemanticLogger::Utils.to_json({point: point})
          end

          it "serializes a Struct passed on its own" do
            assert_equal '{"x":1}', SemanticLogger::Utils.to_json(Struct.new(:x).new(1))
          end

          it "writes a member with #to_s like any other value, not #inspect" do
            account = Data.define(:id, :client).new(id: 7, client: client)
            result  = SemanticLogger::Utils.to_json({account: account})

            assert_equal '{"account":{"id":7,"client":"#<Client>"}}', result
            refute_includes result, "secret"
          end

          it "repairs the members of a Struct" do
            values = Struct.new(:ratio, :name).new(Float::NAN, "Bad: \xE2".b)

            assert_equal '{"values":{"ratio":"NaN","name":"Bad: "}}', SemanticLogger::Utils.to_json({values: values})
          end

          it "serializes Structs nested within Structs, Hashes, and Arrays" do
            node   = Struct.new(:name, :children)
            tree   = node.new("root", [node.new("leaf", {size: 1})])
            parsed = JSON.parse(SemanticLogger::Utils.to_json({tree: tree}))

            assert_equal({"name" => "root", "children" => [{"name" => "leaf", "children" => {"size" => 1}}]},
                         parsed["tree"])
          end

          it "leaves a String that looks like an inspected Struct unchanged" do
            message = "#<struct Point x=1>"

            assert_equal %({"message":"#{message}"}), SemanticLogger::Utils.to_json({message: message})
          end

          it "replaces a Struct nested too deeply with a placeholder naming its class" do
            nested = DeepNode.new(1)
            40.times { nested = DeepNode.new(nested) }

            assert_includes SemanticLogger::Utils.to_json({payload: nested}),
                            '"#<SemanticLogger::UtilsTest::DeepNode nested too deeply>"'
          end

          it "serializes Structs nested 100,000 levels deep on a thread without exhausting the stack" do
            # The json gem writes a Struct through Struct#inspect, which has no depth limit
            # and raises SystemStackError a few hundred levels deep on a thread's smaller
            # stack. This is the only test that exhausts the stack: Ruby 3.2 can crash
            # when a process does so a second time.
            node   = Struct.new(:child)
            nested = 1
            100_000.times { nested = node.new(nested) }

            result = Thread.new { SemanticLogger::Utils.to_json({payload: nested}) }.value

            assert_includes result, "nested too deeply"
          end

          it "replaces a structure nested too deeply within a Struct with a placeholder" do
            # A request body as deep as JSON.parse accepts, held by a Struct.
            request = Struct.new(:body).new(JSON.parse("#{'{"a":' * 99}1#{'}' * 99}"))

            assert_includes SemanticLogger::Utils.to_json({payload: request}), '"#<Hash nested too deeply>"'
          end

          it "ends the recursion when #to_h does not return a Hash" do
            odd = Struct.new(:x) do
              def to_h = self
            end.new(1)

            assert_includes SemanticLogger::Utils.to_json({odd: odd}), "nested too deeply"
          end
        end
      end

      describe ".to_json with a Set, OpenStruct, or Exception" do
        let(:client) do
          Class.new do
            def initialize
              @password = "hunter2"
            end
          end.new
        end

        it "writes a Set as an array, not its #inspect" do
          result = SemanticLogger::Utils.to_json({clients: Set[client, 1]})

          refute_includes result, "hunter2"
          assert_equal 1, JSON.parse(result)["clients"].last
        end

        it "writes a Set of plain values as an array, on Ruby 4.0 too, where its #inspect has no #<" do
          result = SemanticLogger::Utils.to_json({ids: Set[1, 2], nested: [Set[3]]})

          assert_equal({"ids" => [1, 2], "nested" => [[3]]}, JSON.parse(result))
        end

        it "writes an OpenStruct as an object, not its #inspect" do
          require "ostruct"
          # An application's OpenStruct, as logged in a payload.
          config = OpenStruct.new(name: "billing", api: client) # rubocop:disable Style/OpenStructUse
          result = SemanticLogger::Utils.to_json({config: config})

          refute_includes result, "hunter2"
          assert_equal "billing", JSON.parse(result)["config"]["name"]
        end

        it "ends the recursion when an OpenStruct's #to_h does not return a Hash" do
          require "ostruct"
          odd = Class.new(OpenStruct) { def to_h = self }.new(a: 1) # rubocop:disable Style/OpenStructUse

          assert_includes(Thread.new { SemanticLogger::Utils.to_json({odd: odd}) }.value, "nested too deeply")
          assert(Thread.new { SemanticLogger::Utils.nested_too_deeply?(odd) }.value)
        end

        it "writes a structure used as a Hash key as its JSON, not its #inspect" do
          result = SemanticLogger::Utils.to_json({Set[client] => 1, Struct.new(:api).new(client) => 2})

          refute_includes result, "hunter2"
          assert_equal [1, 2], JSON.parse(result).values
        end

        it "keeps a Struct's own #to_json when other text in the entry holds #<" do
          point  = Struct.new(:x) { def to_json(*) = '{"custom":true}' }.new(1)
          result = SemanticLogger::Utils.to_json({message: "undefined method 'x' for #<Foo>", point: point})

          assert_equal({"custom" => true}, JSON.parse(result)["point"])
        end

        it "writes an Exception as its message, repairing invalid UTF-8" do
          error = RuntimeError.new((+"bad \xFF input").force_encoding(Encoding::UTF_8))

          assert_equal({"error" => "bad  input"}, JSON.parse(SemanticLogger::Utils.to_json({error: error})))
        end
      end

      describe ".json_ready" do
        it "returns the value itself when JSON can write it" do
          value = {a: [1, "b"], c: {d: nil}}

          assert_same value, SemanticLogger::Utils.json_ready(value)
        end

        it "returns a copy that JSON can write otherwise" do
          assert_equal({amount: "Infinity"}, SemanticLogger::Utils.json_ready({amount: Float::INFINITY}))
        end
      end

      describe ".structure?" do
        it "is true for the values json_safe writes as an object or array" do
          [{}, [], Set[], Struct.new(:a).new(1), Data.define(:a).new(a: 1)].each do |value|
            assert SemanticLogger::Utils.structure?(value), "for #{value.inspect}"
          end
        end

        it "is false for other values" do
          ["text", 1, :sym, nil, Object.new].each do |value|
            refute SemanticLogger::Utils.structure?(value), "for #{value.inspect}"
          end
        end
      end

      describe ".safe_inspect" do
        it "returns #inspect for a value that can be inspected" do
          assert_equal({a: [1, "b"]}.inspect, SemanticLogger::Utils.safe_inspect({a: [1, "b"]}))
        end

        it "renders a structure too deep for #inspect, cut off with a placeholder, on a thread" do
          nested = "leaf"
          5_000.times { nested = {a: nested} }

          text = Thread.new { SemanticLogger::Utils.safe_inspect(nested) }.value

          assert_includes text, "#<Hash nested too deeply>"
          refute_includes text, "leaf"
        end

        it "renders with the block instead of #inspect, from the cut-off copy when too deep" do
          nested = "leaf"
          5_000.times { nested = {a: nested} }

          assert_equal "1 entries", SemanticLogger::Utils.safe_inspect({a: 1}) { |value| "#{value.size} entries" }
          assert_includes(Thread.new { SemanticLogger::Utils.safe_inspect(nested, &:to_s) }.value,
                          "#<Hash nested too deeply>")
        end

        it "renders a structure that holds itself more than once, without copying it exponentially" do
          looped     = {}
          looped[:a] = looped
          looped[:b] = looped

          text = Timeout.timeout(5) { SemanticLogger::Utils.safe_inspect(looped) }

          assert_equal({a: "#<Hash nested too deeply>", b: "#<Hash nested too deeply>"}.inspect, text)
        end

        it "renders the same structure repeatedly on one thread, without overflowing the stack" do
          nested = "leaf"
          5_000.times { nested = [nested] }

          texts = Thread.new { Array.new(3) { SemanticLogger::Utils.safe_inspect({body: nested}) } }.value

          assert_equal 1, texts.uniq.size
          assert_includes texts.first, "#<Array nested too deeply>"
        end
      end

      describe ".nested_too_deeply?" do
        def chain(levels, &wrap)
          levels.times.reduce("leaf") { |inner, _| wrap.call(inner) }
        end

        it "is false up to the depth that json_safe keeps, and true beyond it" do
          depth = SemanticLogger::Utils::MAX_JSON_SAFE_DEPTH

          refute SemanticLogger::Utils.nested_too_deeply?(chain(depth) { |inner| {a: inner} })
          assert SemanticLogger::Utils.nested_too_deeply?(chain(depth + 1) { |inner| {a: inner} })
          assert SemanticLogger::Utils.nested_too_deeply?(chain(depth + 1) { |inner| [inner] })
        end

        it "looks inside Hash keys, Structs, and Data" do
          depth  = SemanticLogger::Utils::MAX_JSON_SAFE_DEPTH + 1
          member = Struct.new(:inner)
          value  = Data.define(:inner)

          assert SemanticLogger::Utils.nested_too_deeply?({chain(depth) { |inner| [inner] } => 1})
          assert SemanticLogger::Utils.nested_too_deeply?(chain(depth) { |inner| member.new(inner) })
          assert SemanticLogger::Utils.nested_too_deeply?(chain(depth) { |inner| value.new(inner: inner) })
        end

        it "is false for values that are not structures" do
          ["text", 1, nil, Object.new].each do |value|
            refute SemanticLogger::Utils.nested_too_deeply?(value)
          end
        end

        it "ends a structure that references itself" do
          looped        = {}
          looped[:self] = looped

          assert SemanticLogger::Utils.nested_too_deeply?(looped)
        end

        it "ends the recursion when #to_h does not return a Hash, as json_safe does" do
          odd = Struct.new(:x) { def to_h = self }.new(1)

          assert(Thread.new { SemanticLogger::Utils.nested_too_deeply?({odd: odd}) }.value)
          assert_includes(Thread.new { SemanticLogger::Utils.safe_inspect({odd: odd}) }.value, "nested too deeply")
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
