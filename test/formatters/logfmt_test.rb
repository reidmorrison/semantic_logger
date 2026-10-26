require_relative "../test_helper"
module SemanticLogger
  module Formatters
    class LogfmtTest < Minitest::Test
      describe Logfmt do
        let(:log_time) do
          Time.utc(2020, 7, 20, 8, 32, 5.375276)
        end

        let(:log) do
          log = SemanticLogger::Log.new("DefaultTest", :info)
          log.time = log_time
          log.tags = tags
          log.named_tags = named_tags
          log
        end

        let(:formatter) do
          formatter = SemanticLogger::Formatters::Logfmt.new(log_host: false, time_key: time_key)
          # Does not use the logger instance for formatting purposes
          formatter.call(log, nil)
          formatter
        end

        let(:set_exception) do
          raise "Oh no"
        rescue StandardError => e
          log.exception = e
        end

        let(:tags) do
          []
        end

        let(:named_tags) do
          {}
        end

        let(:time_key) do
          :timestamp
        end

        describe "call" do
          it "parses log to logfmt" do
            assert_match formatter.call(log, nil),
                         %(timestamp="2020-07-20T08:32:05.375276Z" level="info" name="DefaultTest" tag="success")
          end

          it "flattens payload information" do
            log.payload = {shrek: "the ogre", controller: "some cotroller"}

            assert_match(/shrek="the ogre" controller="some cotroller"/, formatter.call(log, nil))
          end

          it "prefixes a payload key named like a core field, instead of replacing the field" do
            log.payload = {name: "shrek"}
            text        = formatter.call(log, nil)

            assert_includes text, %( name="DefaultTest" )
            assert_includes text, %( payload.name="shrek")
          end

          it "formats a Struct in the payload as a single quoted field" do
            log.payload = {point: Struct.new(:x, :y).new(1, 2)}

            assert_includes formatter.call(log, nil), %( point="{\\"x\\":1,\\"y\\":2}")
          end

          describe "when no exception found" do
            it "has tag success" do
              assert_match(/tag="success"/, formatter.call(log, nil))
            end
          end

          describe "when exception ocurrs" do
            it "has tag exception" do
              set_exception

              assert_match(/tag="exception"/, formatter.call(log, nil))
            end

            it "flattens exception info" do
              set_exception

              assert_includes formatter.call(log, nil), %( exception_message="Oh no")
            end

            it "flattens the stacktrace" do
              set_exception

              assert_match(/stack_trace="\[\\"/, formatter.call(log, nil))
            end

            it "keeps the entry's name and message, emitting the exception's as separate fields" do
              log.message = "Login failed"
              log.payload = {name: "shrek", exception_message: "forged"}
              set_exception
              text = formatter.call(log, nil)

              assert_includes text, %( name="DefaultTest" message="Login failed" )
              assert_includes text, %( exception_name="RuntimeError" exception_message="Oh no")
              assert_includes text, %( payload.name="shrek" payload.exception_message="forged")
            end
          end

          describe "given a set of tags" do
            let(:tags) do
              %w[ruby rails]
            end

            it "formats the tag as a 'true' value" do
              text = formatter.call(log, nil)

              assert_match(/ruby=true/, text)
              assert_match(/rails=true/, text)
            end

            describe "given a payload with tags key" do
              it "includes the value as a separate field" do
                log.payload = {tags: "apples,bananas,pears"}

                text = formatter.call(log, nil)

                assert_match(/ruby=true/, text)
                assert_match(/rails=true/, text)
                assert_match(/tags="apples,bananas,pears"/, text)
              end
            end
          end

          describe "given a invalid tag names" do
            let(:tags) do
              ["second breakfast", '"elevensies"', "'lunch'"]
            end

            it "replaces the characters that would break the logfmt structure" do
              text = formatter.call(log, nil)

              assert_match(/ second_breakfast=true/, text)
              assert_match(/ _elevensies_=true/, text)
              assert_match(/ 'lunch'=true/, text)
            end
          end

          describe "given untrusted keys" do
            let(:tags) do
              [%(Mozilla level="fatal" name="Billing"\ninjected_line=true)]
            end

            it "cannot inject fields or lines through a tag" do
              text = formatter.call(log, nil)

              assert_equal 1, text.lines.count
              assert_equal 1, text.scan(/(?:\A| )level=/).count
              assert_equal 1, text.scan(/(?:\A| )name=/).count
              assert_includes text, %( Mozilla_level__fatal__name__Billing__injected_line_true=true)
            end

            it "formats nested values as quoted JSON, not #inspect" do
              client = Object.new
              client.instance_variable_set(:@password, "secret")
              log.payload = {user: {id: 7, roles: %w[a b]}, client: [client]}
              text        = formatter.call(log, nil)

              assert_includes text, %( user="{\\"id\\":7,\\"roles\\":[\\"a\\",\\"b\\"]}")
              refute_includes text, "secret"
            end

            it "formats a payload that is not a Hash as a single field" do
              log.payload = "not a hash"

              assert_match(/ payload="not a hash"/, formatter.call(log, nil))
            end

            it "lets a payload that is not a Hash replace a tag of the same name" do
              log.tags    = ["payload"]
              log.payload = "not a hash"
              text        = formatter.call(log, nil)

              assert_match(/ tag="success" payload="not a hash"\z/, text)
            end

            it "cannot inject fields through a payload or named tag key" do
              log.named_tags = {"a b=c" => "1"}
              log.payload    = {"x\ny" => "2", "" => "3"}
              text           = formatter.call(log, nil)

              assert_equal 1, text.lines.count
              assert_includes text, %( a_b_c="1")
              assert_includes text, %( x_y="2")
              assert_includes text, %( _="3")
            end

            it "prefixes a String key named like a core field, keeping the core field" do
              log.payload = {"level" => "debug"}
              text        = formatter.call(log, nil)

              assert_equal 1, text.scan(/(?:\A| )level=/).count
              assert_includes text, %(level="info")
              assert_includes text, %( payload.level="debug")
            end

            it "replaces the Unicode line and paragraph separators" do
              log.tags = ["a b c\u0085d"]
              text     = formatter.call(log, nil)

              assert_includes text, " a_b_c_d=true"
            end

            it "drops invalid UTF-8 from a tag" do
              log.tags = ["ab\xFFc"]
              text     = formatter.call(log, nil)

              assert_includes text, " abc=true"
            end

            it "drops invalid UTF-8 from a payload key" do
              log.payload = {"k\xFF" => "v"}
              text        = formatter.call(log, nil)

              assert_includes text, %( k="v")
            end

            it "converts a binary key to UTF-8 alongside a non-ASCII value" do
              log.payload = {"k\xE9".b => "café"}
              text        = formatter.call(log, nil)

              assert_equal Encoding::UTF_8, text.encoding
              assert_includes text, %( k="café")
            end
          end

          describe "given keys that only collide once encoded" do
            let(:log) do
              log = SemanticLogger::Log.new("DefaultTest", :info)
              log.time       = log_time
              log.message    = "real message"
              log.duration   = 12.5
              log.tags       = tags
              log.named_tags = named_tags
              log
            end

            let(:core_fields) do
              %(timestamp="2020-07-20T08:32:05.375276Z" level="info" name="DefaultTest" message="real message")
            end

            describe "tags named like core fields" do
              let(:tags) do
                %w[message level name timestamp tag]
              end

              it "keeps the core fields, prefixing the tags" do
                text = formatter.call(log, nil)

                assert_equal core_fields, text[0, core_fields.size]
                assert_includes text, %( tag="success")
                assert_includes text, " tags.message=true tags.level=true tags.name=true"
                assert_includes text, " tags.timestamp=true tags.tag=true"
              end
            end

            describe "named tags named like core fields" do
              let(:named_tags) do
                {"message" => "forged", "level" => "fatal", "duration_ms" => "0"}
              end

              it "keeps the core fields, prefixing the named tags" do
                text = formatter.call(log, nil)

                assert_equal core_fields, text[0, core_fields.size]
                assert_includes text, " duration_ms=12.5"
                assert_includes text, %( named_tags.message="forged" named_tags.level="fatal")
                assert_includes text, %( named_tags.duration_ms="0")
              end
            end

            describe "keys that collide after sanitizing" do
              let(:tags) do
                ["duration ms"]
              end

              let(:named_tags) do
                {"a b" => "first"}
              end

              it "keeps the field from the later source" do
                log.payload = {"a=b" => "second"}
                text        = formatter.call(log, nil)

                assert_equal core_fields, text[0, core_fields.size]
                assert_includes text, " duration_ms=12.5"
                assert_includes text, " tags.duration_ms=true"
                assert_includes text, %( a_b="second")
                refute_includes text, "first"
              end
            end

            describe "a payload with the same keys as the core fields" do
              it "keeps the core fields, prefixing the payload's" do
                log.payload = {name: "shrek", message: "from payload", duration_ms: 1, timestamp: "2001", tag: "x"}
                text        = formatter.call(log, nil)

                assert_equal core_fields, text[0, core_fields.size]
                assert_includes text, " duration_ms=12.5 "
                assert_includes text, %( payload.name="shrek" payload.message="from payload" payload.duration_ms=1)
                assert_includes text, %( payload.timestamp="2001" payload.tag="x")
                assert_equal 1, text.scan(/(?:\A| )name=/).count
                assert_equal 1, text.scan(/(?:\A| )message=/).count
              end
            end

            describe "keys that start with a source prefix" do
              it "prefixes them too, so that they cannot replace or forge a prefixed key" do
                log.tags       = ["payload.level"]
                log.named_tags = {level: "real"}
                log.payload    = {"named_tags.level" => "forged", :level => "debug", "tags" => "kept"}
                text           = formatter.call(log, nil)

                assert_includes text, %( tag="success" tags.payload.level=true named_tags.level="real")
                assert_includes text, %( payload.named_tags.level="forged" payload.level="debug" tags="kept")
              end
            end

            describe "keys named like the exception's fields" do
              it "prefixes them, so that they cannot forge an exception" do
                log.payload = {"stack_trace" => "forged", cause: "forged", exception_name: "Forged"}
                text        = formatter.call(log, nil)

                assert_includes text, %( tag="success")
                assert_includes text, %( payload.stack_trace="forged" payload.cause="forged")
                assert_includes text, %( payload.exception_name="Forged")
              end
            end
          end

          describe "given only plain keys" do
            let(:tags) do
              %w[web 4f3c2a]
            end

            let(:named_tags) do
              {request_id: "abc-123"}
            end

            let(:expected) do
              [
                %(timestamp="2020-07-20T08:32:05.375276Z" level="info" name="DefaultTest" tag="success"),
                %(web=true 4f3c2a=true request_id="abc-123" count=42 big=1180591620717411303424),
                %(yes=true no=false none=null ratio=0.5 path="/users/42")
              ].join(" ")
            end

            before do
              log.payload = {count: 42, big: 2**70, yes: true, no: false, none: nil, ratio: 0.5, path: "/users/42"}
            end

            it "formats every field" do
              assert_equal expected, formatter.call(log, nil)
            end

            it "formats the same fields when another key needs encoding" do
              log.payload = log.payload.merge("a b" => 1)

              assert_equal "#{expected} a_b=1", formatter.call(log, nil)
            end

            it "formats the same fields on every call" do
              3.times { assert_equal expected, formatter.call(log, nil) }
            end
          end

          describe "given a plain key and a later key that encodes to the same text" do
            it "keeps the value of the later key" do
              log.tags    = ["a_b"]
              log.payload = {"a b" => "second", "c d" => 1, e: 2}
              text        = formatter.call(log, nil)

              assert_match(/ a_b="second" c_d=1 e=2\z/, text)
            end
          end

          describe "given a Symbol and a String key with the same name" do
            it "lets a payload Symbol key replace a tag" do
              log.tags    = ["user"]
              log.payload = {user: "bob", other: 1}
              text        = formatter.call(log, nil)

              assert_match(/ user="bob" other=1\z/, text)
            end

            it "lets a payload String key replace a Symbol named tag" do
              log.named_tags = {user: "named"}
              log.payload    = {"user" => "payload"}
              text           = formatter.call(log, nil)

              assert_match(/ user="payload"\z/, text)
            end

            it "lets a String named tag replace a tag" do
              log.tags       = ["user"]
              log.named_tags = {"user" => "named"}
              text           = formatter.call(log, nil)

              assert_match(/ user="named"\z/, text)
            end

            it "keeps the later key in the payload, whether or not it is reserved" do
              log.payload = {:user => 1, "user" => 2, :level => 1, "level" => 2}
              text        = formatter.call(log, nil)

              assert_match(/ user=2 payload.level=2\z/, text)
            end
          end

          describe "given many distinct Symbol keys" do
            it "formats them all while remembering a bounded number" do
              keys        = Array.new(Logfmt::PLAIN_SYMBOL_CACHE_SIZE + 10) { |i| :"key#{i}" }
              log.payload = keys.to_h { |key| [key, 1] }
              text        = formatter.call(log, nil)

              assert_includes text, " key0=1 "
              assert_match(/ key#{keys.size - 1}=1\z/, text)
              assert_equal Logfmt::PLAIN_SYMBOL_CACHE_SIZE, formatter.instance_variable_get(:@plain_symbols).size
            end
          end

          describe "given a Symbol key that needs encoding" do
            it "encodes it on every call" do
              log.payload = {"a b": 1}

              2.times { assert_match(/ a_b=1\z/, formatter.call(log, nil)) }
            end
          end

          describe "given a payload holding a structure that is not a Hash or an Array" do
            it "quotes its JSON, so that a space or an = in it cannot add a field" do
              require "ostruct"
              written = Object.new
              def written.to_json(*) = '{"a":"b level=error"}'
              log.payload = {
                roles: Set["admin user", "x level=error"],
                cfg:   OpenStruct.new(a: "b c"), # rubocop:disable Style/OpenStructUse
                obj:   written
              }

              output = formatter.call(log, nil)

              assert_includes output, %(roles="[\\"admin user\\",\\"x level=error\\"]")
              assert_includes output, %(cfg="{\\"a\\":\\"b c\\"}")
              assert_includes output, %(obj="{\\"a\\":\\"b level=error\\"}")
            end
          end

          describe "given a set of named tags" do
            let(:named_tags) do
              {
                base:          "breakfast",
                spaces:        "second breakfast",
                double_quotes: '"elevensies"',
                single_quotes: "'lunch'"
              }
            end

            it "flattens them into the message" do
              text = formatter.call(log, nil)

              assert_match(/base="breakfast"/, text)
              assert_match(/spaces="second breakfast"/, text)
              assert_match(/double_quotes="\\"elevensies\\""/, text)
              assert_match(/single_quotes="'lunch'"/, text)
            end

            describe "given a payload with conflicting keys" do
              it "overrides the named tags" do
                log.payload = {spaces: "You shall not pass"}

                text = formatter.call(log, nil)

                assert_match(/base="breakfast"/, text)
                refute_match(/spaces="second breakfast"/, text)
                assert_match(/spaces="You shall not pass"/, text)
                assert_match(/double_quotes="\\"elevensies\\""/, text)
                assert_match(/single_quotes="'lunch'"/, text)
              end
            end
          end

          describe "given an time_key" do
            let(:time_key) do
              :ts
            end

            it "overrides the timestamp" do
              text = formatter.call(log, nil)

              refute_match(/timestamp=/, text)
              assert_match(/ts="2020-07-20T08:32:05.375276Z"/, text)
            end

            it "keeps the time key, prefixing a payload key of the same name" do
              log.payload = {ts: "forged"}
              text        = formatter.call(log, nil)

              assert_match(/\Ats="2020-07-20T08:32:05.375276Z" /, text)
              assert_includes text, %( payload.ts="forged")
            end

            it "keeps a time key that is set after the formatter is created" do
              log.payload = {time: "before"}
              formatter.call(log, nil)
              formatter.time_key = :time
              log.payload        = {time: "forged", ts: "not reserved"}
              text               = formatter.call(log, nil)

              assert_match(/\Atime="2020-07-20T08:32:05.375276Z" /, text)
              assert_includes text, %( payload.time="forged" ts="not reserved")
            end
          end
        end
      end
    end
  end
end
