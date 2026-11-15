require_relative "test_helper"
# OpenStruct, as an application can log one: a bundled gem since Ruby 4.0.
require "ostruct"

class RedactorTest < Minitest::Test
  # Answers as ActiveSupport::ParameterFilter#filter_param does: the mask for a sensitive key name,
  # and otherwise the value it is given.
  class FakeParameterFilter
    def initialize(names, mask: "[FILTERED]")
      @names = names
      @mask  = mask
    end

    def filter_param(key, value)
      @names.include?(key) ? @mask : value
    end
  end

  describe SemanticLogger::Redactor do
    let(:sensitive_keys) { %i[password authorization] }
    let(:redactor) { SemanticLogger::Redactor.new(sensitive_keys) }
    let(:mask) { SemanticLogger::Redactor::MASK }

    describe "#initialize" do
      it "keeps the sensitive keys as supplied" do
        assert_same sensitive_keys, redactor.sensitive_keys
      end

      it "accepts an Array of Symbols, Strings, and Regexps, a Regexp, a #filter_param, or a #call" do
        filter = FakeParameterFilter.new(%w[password])

        [[:password, "secret", /token/], /password/, filter, ->(_name) { false }].each do |keys|
          assert_same keys, SemanticLogger::Redactor.new(keys).sensitive_keys
        end
      end

      it "rejects any other value" do
        [nil, true, "password", :password, 42].each do |keys|
          error = assert_raises(ArgumentError, keys.inspect) { SemanticLogger::Redactor.new(keys) }

          assert_includes error.message, "Expected sensitive keys as an Array of Symbols, Strings, or Regexps"
        end
      end

      it "rejects an Array holding anything but Symbols, Strings, and Regexps" do
        [[:password, 42], [->(_name) { true }], [nil]].each do |keys|
          error = assert_raises(ArgumentError, keys.inspect) { SemanticLogger::Redactor.new(keys) }

          assert_includes error.message, "Expected each sensitive key to be a Symbol, String, or Regexp"
        end
      end
    end

    describe "#replacement_for" do
      describe "with an Array" do
        let(:sensitive_keys) { [:passw, "Secret", /\Atoken\z/] }

        it "matches a key name containing a Symbol or String, ignoring case" do
          %i[password user_password PASSWORD].each { |key| assert_equal mask, redactor.replacement_for(key), key }
          %w[secret client_secret SECRET_KEY].each { |key| assert_equal mask, redactor.replacement_for(key), key }
        end

        it "matches a Regexp as written" do
          assert_equal mask, redactor.replacement_for(:token)
          assert_nil redactor.replacement_for(:max_tokens)
        end

        it "matches a case sensitive Regexp with the key name in snake_case too, which is lower case" do
          assert_equal mask, redactor.replacement_for(:TOKEN)
        end

        it "escapes the characters of a String that a Regexp would treat as special" do
          redactor = SemanticLogger::Redactor.new(["a.b"])

          assert_equal mask, redactor.replacement_for("a.b")
          assert_nil redactor.replacement_for("axb")
        end

        it "matches nothing when empty" do
          assert_nil SemanticLogger::Redactor.new([]).replacement_for(:password)
        end
      end

      it "matches a Regexp" do
        redactor = SemanticLogger::Redactor.new(/pass/i)

        assert_equal mask, redactor.replacement_for(:Password)
        assert_nil redactor.replacement_for(:user)
      end

      it "uses the replacement that #filter_param returns" do
        redactor = SemanticLogger::Redactor.new(FakeParameterFilter.new(%w[password], mask: "***"))

        assert_equal "***", redactor.replacement_for(:password)
        assert_nil redactor.replacement_for(:user)
      end

      it "asks #filter_param about the key name with a nil value" do
        filter = Minitest::Mock.new
        filter.expect(:filter_param, nil, ["user", nil])
        SemanticLogger::Redactor.new(filter).replacement_for(:user)

        filter.verify
      end

      it "takes a false answer from #filter_param as not sensitive" do
        filter = Object.new
        def filter.filter_param(_key, _value) = false

        assert_nil SemanticLogger::Redactor.new(filter).replacement_for(:password)
      end

      it "masks a key for which #call returns true" do
        redactor = SemanticLogger::Redactor.new(->(name) { name == "password" })

        assert_equal mask, redactor.replacement_for(:password)
        assert_nil redactor.replacement_for(:user)
      end

      it "prefers #filter_param when the sensitive keys also respond to #call" do
        filter = FakeParameterFilter.new(%w[password], mask: "from filter_param")
        def filter.call(_name) = true

        redactor = SemanticLogger::Redactor.new(filter)

        assert_equal "from filter_param", redactor.replacement_for(:password)
        assert_nil redactor.replacement_for(:user)
      end

      it "matches String and Symbol keys alike" do
        assert_equal mask, redactor.replacement_for("password")
        assert_equal mask, redactor.replacement_for(:password)
      end

      it "never matches a key that is neither a Symbol nor a String" do
        redactor = SemanticLogger::Redactor.new(->(_name) { true })

        [42, nil, [:password], {password: 1}].each { |key| assert_nil redactor.replacement_for(key), key.inspect }
      end

      it "also matches the key name in snake_case" do
        redactor = SemanticLogger::Redactor.new(%w[_key authorization])

        %w[X-Api-Key apiKey API_KEY x.api.key].each { |key| assert_equal mask, redactor.replacement_for(key), key }
        assert_equal mask, redactor.replacement_for("HTTP_AUTHORIZATION")
        assert_nil redactor.replacement_for("monkey")
      end

      it "asks about the key name as written first, and in snake_case only when that is not sensitive" do
        names    = []
        redactor = SemanticLogger::Redactor.new(->(name) { (names << name) && false })
        redactor.replacement_for("X-Api-Key")
        redactor.replacement_for(:user_id)

        assert_equal %w[X-Api-Key x_api_key user_id], names
      end

      it "matches a key name with invalid bytes, or in another encoding, without raising" do
        assert_equal mask, redactor.replacement_for((+"pass\xFFword").force_encoding(Encoding::UTF_8))
        assert_equal mask, redactor.replacement_for("password".b)
        assert_equal mask, redactor.replacement_for("password".encode(Encoding::UTF_16LE))
      end

      it "remembers the answer for each key" do
        names    = []
        redactor = SemanticLogger::Redactor.new(->(name) { (names << name) && name == "password" })
        3.times do
          assert_equal mask, redactor.replacement_for(:password)
          assert_nil redactor.replacement_for(:user)
        end

        assert_equal %w[password user], names
      end

      it "remembers no more than MAX_REMEMBERED_KEYS keys" do
        asked    = 0
        redactor = SemanticLogger::Redactor.new(->(_name) { (asked += 1) && false })
        SemanticLogger::Redactor::MAX_REMEMBERED_KEYS.times { |i| redactor.replacement_for("key#{i}") }
        asked = 0
        2.times { redactor.replacement_for("one_more") }
        redactor.replacement_for("key0")

        assert_equal 2, asked
      end
    end

    describe "#redact" do
      it "replaces the value of a sensitive key" do
        assert_equal({user: "jack", password: mask}, redactor.redact(user: "jack", password: "secret"))
      end

      it "replaces the value of a sensitive key at any depth" do
        payload = {request: {headers: {"Authorization" => "Bearer abc"}}, users: [{password: "a"}, {password: "b"}]}
        redacted = {request: {headers: {"Authorization" => mask}}, users: [{password: mask}, {password: mask}]}

        assert_equal redacted, redactor.redact(payload)
      end

      it "replaces the whole value of a sensitive key, even a structure" do
        assert_equal({authorization: mask}, redactor.redact(authorization: {scheme: "Bearer", token: "abc"}))
      end

      it "leaves the supplied value, and the structures in it, unchanged" do
        payload = {user: {name: "jack", password: "secret"}, list: [{password: "x"}]}
        before  = Marshal.load(Marshal.dump(payload))
        redactor.redact(payload)

        assert_equal before, payload
      end

      it "returns the value itself when it has no sensitive key" do
        payload = {user: {name: "jack"}, list: [1, {id: 2}], user_struct: Struct.new(:name).new("jack")}

        assert_same payload, redactor.redact(payload)
      end

      it "keeps the structures that hold no sensitive key" do
        payload  = {user: {name: "jack"}, password: "secret", list: [1, 2]}
        redacted = redactor.redact(payload)

        assert_same payload[:user], redacted[:user]
        assert_same payload[:list], redacted[:list]
      end

      it "keeps the order of the keys, and of the elements before and after a change" do
        payload = {a: 1, password: "x", b: 2}

        assert_equal %i[a password b], redactor.redact(payload).keys
        assert_equal [1, {password: mask}, 3], redactor.redact([1, {password: "x"}, 3])
      end

      it "copies a Hash that compares its keys by identity as one that does" do
        payload = {}.compare_by_identity
        payload[+"user"]     = "jack"
        payload[+"password"] = "secret"
        redacted = redactor.redact(payload)

        assert_predicate redacted, :compare_by_identity?
        assert_equal ["jack", mask], redacted.values
      end

      it "returns a value that is not a structure as it is" do
        assert_nil redactor.redact(nil)
        ["password", :password, 42, 1.5, true, Object.new].each do |value|
          assert_same value, redactor.redact(value)
        end
      end

      it "returns a Hash for a Struct, Data, or OpenStruct with a sensitive member" do
        data_class = Data.define(:user, :password)

        assert_equal({user: "jack", password: mask}, redactor.redact(Struct.new(:user, :password).new("jack", "x")))
        assert_equal({user: "jack", password: mask}, redactor.redact(data_class.new(user: "jack", password: "x")))
        # An application's OpenStruct, as logged in a payload.
        open_struct = OpenStruct.new(user: "jack", password: "x") # rubocop:disable Style/OpenStructUse

        assert_equal({user: "jack", password: mask}, redactor.redact(open_struct))
      end

      it "returns a Struct, Data, or OpenStruct with no sensitive member as it is" do
        open_struct = OpenStruct.new(user: "jack") # rubocop:disable Style/OpenStructUse

        [Struct.new(:user).new("jack"), Data.define(:user).new(user: "jack"), open_struct].each do |value|
          assert_same value, redactor.redact(value)
        end
      end

      it "returns an Array for a Set holding a sensitive key" do
        assert_equal [{password: mask}, 1], redactor.redact(Set[{password: "x"}, 1])
      end

      it "reads an object that responds to #to_unsafe_h, such as ActionController::Parameters" do
        params = Object.new
        def params.to_unsafe_h = {"user" => "jack", "password" => "x"}

        assert_equal({"user" => "jack", "password" => mask}, redactor.redact(list: [params])[:list].first)
      end

      it "redacts a structure held more than once once, and shares its copy" do
        shared   = {password: "x"}
        redacted = redactor.redact(a: shared, b: shared)

        assert_equal({password: mask}, redacted[:a])
        assert_same redacted[:a], redacted[:b]
      end

      it "cuts off a structure that holds itself, rather than copying the original into it" do
        payload = {password: "x"}
        payload[:self] = payload

        assert_equal({password: mask, self: SemanticLogger::Redactor::CIRCULAR}, redactor.redact(payload))
      end

      it "cuts off an Array that holds itself, even with no sensitive key" do
        list = [1]
        list << list

        assert_equal [1, SemanticLogger::Redactor::CIRCULAR], redactor.redact(list)
      end

      it "replaces a structure nested deeper than MAX_DEPTH, without overflowing the stack" do
        deep = (1..10_000).reduce({password: "x"}) { |inner, _| {inner: inner} }
        redacted = redactor.redact(deep)
        depth    = 0
        value    = redacted
        while value.is_a?(Hash)
          value  = value[:inner]
          depth += 1
        end

        assert_equal SemanticLogger::Redactor::MAX_DEPTH, depth
        assert_equal SemanticLogger::Redactor::NESTED_TOO_DEEPLY, value
      end

      describe "when the sensitive keys raise" do
        let(:io) { StringIO.new }
        let(:redactor) { SemanticLogger::Redactor.new(->(_name) { raise "broken by secret-value" }) }

        def internal_processor
          SemanticLogger::SyncProcessor.new(SemanticLogger::Appenders.new(SemanticLogger::Appender::IO.new(io)))
        end

        def redact_reporting_to_io(value, redactor = self.redactor)
          SemanticLogger::Logger.stub(:processor, internal_processor) { redactor.redact(value) }
        end

        it "replaces the whole value, failing closed" do
          assert_equal({redaction_failed: "RuntimeError"}, redact_reporting_to_io({user: "jack", password: "x"}))
        end

        it "reports the error class, and where it was raised, to the internal logger, but not its message" do
          redact_reporting_to_io({password: "x"})

          assert_match(/W .*Redacting sensitive keys raised RuntimeError \(.*redactor_test\.rb:\d+/, io.string)
          assert_includes io.string, "so the value was replaced with :redaction_failed"
          refute_includes io.string, "secret-value"
        end

        it "names an error class without a name" do
          error_class = Class.new(StandardError)
          redactor    = SemanticLogger::Redactor.new(->(_name) { raise error_class })

          assert_equal({redaction_failed: error_class.inspect}, redact_reporting_to_io({password: "x"}, redactor))
        end

        it "asks again for a key next time, since nothing is remembered for it" do
          asked    = 0
          redactor = SemanticLogger::Redactor.new(->(_name) { (asked += 1) && raise("broken") })
          2.times { redact_reporting_to_io({password: "x"}, redactor) }

          assert_equal 2, asked
        end
      end
    end
  end
end
