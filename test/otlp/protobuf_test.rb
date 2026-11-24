require_relative "../test_helper"

module Otlp
  # The expected bytes are worked out by hand from the Protobuf encoding
  # (https://protobuf.dev/programming-guides/encoding/) and the field numbers of opentelemetry-proto.
  class ProtobufTest < Minitest::Test
    describe SemanticLogger::Otlp::Protobuf do
      def encode(hash, message)
        SemanticLogger::Otlp::Protobuf.encode(hash, message)
      end

      # Returns [String] the bytes of the hex text, with spaces between them.
      def bytes(hex)
        [hex.delete(" ")].pack("H*")
      end

      describe ".encode" do
        it "returns binary text" do
          assert_equal Encoding::BINARY, encode({stringValue: "é"}, :AnyValue).encoding
        end

        it "writes a string as its UTF-8 bytes" do
          assert_equal bytes("0a 02 c3a9"), encode({stringValue: "é"}, :AnyValue)
        end

        it "writes a Symbol as its name" do
          assert_equal bytes("0a 01 61"), encode({stringValue: :a}, :AnyValue)
        end

        it "writes a bool, even false" do
          assert_equal bytes("10 00"), encode({boolValue: false}, :AnyValue)
          assert_equal bytes("10 01"), encode({boolValue: true}, :AnyValue)
        end

        it "writes an int64 from a decimal String, as a varint" do
          assert_equal bytes("18 9601"), encode({intValue: "150"}, :AnyValue)
          assert_equal bytes("18 00"), encode({intValue: 0}, :AnyValue)
        end

        it "writes a negative int64 as ten bytes" do
          assert_equal bytes("18 ffffffffffffffffff01"), encode({intValue: "-1"}, :AnyValue)
        end

        it "writes a double, and the text of one that is not finite" do
          assert_equal bytes("21 000000000000f83f"), encode({doubleValue: 1.5}, :AnyValue)
          assert_equal bytes("21 000000000000f87f"), encode({doubleValue: "NaN"}, :AnyValue)
          assert_equal bytes("21 000000000000f07f"), encode({doubleValue: "Infinity"}, :AnyValue)
          assert_equal bytes("21 000000000000f0ff"), encode({doubleValue: "-Infinity"}, :AnyValue)
        end

        it "writes a fixed64 and an sfixed64 from decimal Strings" do
          assert_equal bytes("19 0100000000000000 31 feffffffffffffff"),
                       encode({timeUnixNano: "1", asInt: "-2"}, :NumberDataPoint)
        end

        it "writes an sint32 zigzag encoded, and a repeated uint64 packed" do
          assert_equal bytes("08 05 12 03 01ac02"), encode({offset: -3, bucketCounts: %w[1 300]}, :Buckets)
          assert_equal bytes("08 06"), encode({offset: 3}, :Buckets)
        end

        it "leaves out an empty packed field" do
          assert_equal bytes("08 00"), encode({offset: 0, bucketCounts: []}, :Buckets)
        end

        it "writes an enum as a varint" do
          assert_equal bytes("10 01 18 01"), encode({aggregationTemporality: 1, isMonotonic: true}, :Sum)
        end

        it "writes an embedded message, and an empty one" do
          assert_equal bytes("0a 01 6b 12 03 18 9601"), encode({key: "k", value: {intValue: "150"}}, :KeyValue)
          assert_equal bytes("0a 01 6b 12 00"), encode({key: "k", value: {}}, :KeyValue)
        end

        it "writes each message of a repeated field apart" do
          array = {arrayValue: {values: [{intValue: "1"}, {boolValue: true}]}}

          assert_equal bytes("2a 08 0a 02 1801 0a 02 1001"), encode(array, :AnyValue)
        end

        it "writes a kvlistValue" do
          kvlist = {kvlistValue: {values: [{key: "a", value: {stringValue: "b"}}]}}

          assert_equal bytes("32 0a 0a 08 0a 01 61 12 03 0a 01 62"), encode(kvlist, :AnyValue)
        end

        it "leaves out a nil value" do
          assert_equal bytes("0a 01 6b"), encode({key: "k", value: nil}, :KeyValue)
        end

        it "takes String keys too" do
          assert_equal bytes("0a 01 6b"), encode({"key" => "k"}, :KeyValue)
        end

        it "writes a request, as the metric encoder builds it" do
          request = {
            resourceMetrics: [
              {
                resource:     {attributes: [{key: "a", value: {stringValue: "b"}}]},
                scopeMetrics: [
                  {
                    scope:   {name: "S"},
                    metrics: [
                      {
                        name: "c",
                        sum:  {
                          dataPoints:             [{timeUnixNano: "1", asInt: "2"}],
                          aggregationTemporality: 1,
                          isMonotonic:            true
                        }
                      }
                    ]
                  }
                ]
              }
            ]
          }
          number_point = "19 0100000000000000 31 0200000000000000"
          sum          = "0a 12 #{number_point} 10 01 18 01"
          metric       = "0a 01 63 3a 18 #{sum}"
          scope        = "0a 03 0a 01 53 12 1d #{metric}"
          resource     = "0a 0a 0a 08 0a 01 61 12 03 0a 01 62"
          expected     = "0a 32 #{resource} 12 24 #{scope}"

          assert_equal bytes(expected), encode(request, :ExportMetricsServiceRequest)
        end

        it "raises for a field that the message does not have" do
          error = assert_raises(SemanticLogger::Otlp::Protobuf::Error) { encode({color: "red"}, :KeyValue) }

          assert_match(/KeyValue has no field :color/, error.message)
        end

        it "raises for a value of the wrong type" do
          assert_raises(SemanticLogger::Otlp::Protobuf::Error) { encode({intValue: "one"}, :AnyValue) }
          assert_raises(SemanticLogger::Otlp::Protobuf::Error) { encode({doubleValue: "big"}, :AnyValue) }
          assert_raises(SemanticLogger::Otlp::Protobuf::Error) { encode({values: {}}, :ArrayValue) }
        end
      end

      describe ".decode" do
        def decode(hex, message)
          SemanticLogger::Otlp::Protobuf.decode(bytes(hex), message)
        end

        it "reads a partial success" do
          assert_equal(
            {"partialSuccess" => {"rejectedDataPoints" => 3, "errorMessage" => "bad"}},
            decode("0a 07 08 03 12 03 626164", :ExportMetricsServiceResponse)
          )
        end

        it "reads a negative int64, and a UTF-8 string" do
          partial = decode("0a 0f 08 ffffffffffffffffff01 12 02 c3a9", :ExportMetricsServiceResponse)["partialSuccess"]

          assert_equal(-1, partial["rejectedDataPoints"])
          assert_equal "é", partial["errorMessage"]
          assert_equal Encoding::UTF_8, partial["errorMessage"].encoding
        end

        it "skips a field that the message does not have, of any wire type" do
          assert_equal(
            {"partialSuccess" => {"rejectedDataPoints" => 1}},
            decode("48 01 51 0000000000000000 5d 00000000 62 01 78 0a 02 08 01", :ExportMetricsServiceResponse)
          )
        end

        it "skips a field of another wire type than its message declares" do
          assert_equal({}, decode("0d 00000000", :ExportMetricsServiceResponse))
        end

        it "reads an empty message" do
          assert_equal({}, decode("", :ExportMetricsServiceResponse))
        end

        it "raises for a truncated message, or an unknown wire type" do
          assert_raises(SemanticLogger::Otlp::Protobuf::Error) { decode("0a 07 08 03", :ExportMetricsServiceResponse) }
          assert_raises(SemanticLogger::Otlp::Protobuf::Error) { decode("0b", :ExportMetricsServiceResponse) }
          assert_raises(SemanticLogger::Otlp::Protobuf::Error) { decode("08 ff", :ExportMetricsServiceResponse) }
        end
      end
    end
  end
end
