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
            log.payload = { shrek: "the ogre", controller: "some cotroller" }
            assert_match(/shrek="the ogre" controller="some cotroller"/, formatter.call(log, nil))
          end

          it "changes name to payload information" do
            log.payload = { name: "shrek" }
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
              log.payload = { name: "shrek" }
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
                log.payload = { tags: "apples,bananas,pears" }

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

            it "formats the tag as a 'true' value" do
              text = formatter.call(log, nil)
              assert_match(/second breakfast=true/, text)
              assert_match(/"elevensies"=true/, text)
              assert_match(/'lunch'=true/, text)
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
                log.payload = { spaces: "You shall not pass" }

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
