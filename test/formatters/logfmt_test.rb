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

          it "changes name to payload information" do
            log.payload = {name: "shrek"}

            assert_match(/name="shrek"/, formatter.call(log, nil))
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

              assert_match(/message="Oh no"/, formatter.call(log, nil))
            end

            it "flattens the stacktrace" do
              set_exception

              assert_match(/stack_trace="\[\\"/, formatter.call(log, nil))
            end

            it "changes name to exception" do
              log.payload = {name: "shrek"}
              set_exception

              assert_match(/name="RuntimeError"/, formatter.call(log, nil))
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

            it "formats a payload that is not a Hash as a single field" do
              log.payload = "not a hash"

              assert_match(/ payload="not a hash"/, formatter.call(log, nil))
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

            it "emits a field once when keys only differ by type, keeping the core field" do
              log.payload = {"level" => "debug"}
              text        = formatter.call(log, nil)

              assert_equal 1, text.scan(/(?:\A| )level=/).count
              assert_includes text, %(level="info")
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

              it "keeps the core fields" do
                text = formatter.call(log, nil)

                assert_equal core_fields, text[0, core_fields.size]
                assert_includes text, %( tag="success")
                refute_includes text, "=true"
              end
            end

            describe "named tags named like core fields" do
              let(:named_tags) do
                {"message" => "forged", "level" => "fatal", "duration_ms" => "0"}
              end

              it "keeps the core fields" do
                text = formatter.call(log, nil)

                assert_equal core_fields, text[0, core_fields.size]
                assert_includes text, " duration_ms=12.5"
                refute_includes text, "forged"
                refute_includes text, "fatal"
              end
            end

            describe "keys that collide after sanitizing" do
              let(:tags) do
                ["duration ms"]
              end

              let(:named_tags) do
                {"a b" => "first"}
              end

              it "keeps the first field" do
                log.payload = {"a=b" => "second"}
                text        = formatter.call(log, nil)

                assert_equal core_fields, text[0, core_fields.size]
                assert_includes text, " duration_ms=12.5"
                assert_includes text, %( a_b="first")
                refute_includes text, "second"
                refute_includes text, "=true"
              end
            end

            describe "a payload with the same keys as the core fields" do
              it "overrides the core fields, as documented" do
                log.payload = {name: "shrek", message: "from payload", duration_ms: 1}
                text        = formatter.call(log, nil)

                assert_includes text, %(level="info" name="shrek" message="from payload")
                assert_includes text, " duration_ms=1 "
                assert_equal 1, text.scan(/(?:\A| )name=/).count
                assert_equal 1, text.scan(/(?:\A| )message=/).count
              end
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
          end
        end
      end
    end
  end
end
