module SemanticLogger
  # Replaces the values of an application's sensitive keys, such as passwords and access tokens, in
  # the keyed data of a log entry: its payload, named tags, context, and metric dimensions (see
  # Log#redact and SemanticLogger.sensitive_keys=).
  #
  # Keys are matched by name, the name of a Symbol key or a String key, both as written and in
  # snake_case, which is lower case, so that "X-Api-Key" and "apiKey" are also asked about as
  # "x_api_key" and "api_key". Keys of any other kind are never sensitive.
  #
  # Internal: built by SemanticLogger.sensitive_keys=, and asked by Log#redact to redact each of
  # an entry's keyed fields, on the thread that writes the entry to the appenders.
  class Redactor
    # The value that replaces a sensitive one, unless the sensitive keys supply their own (see
    # #initialize). The same as Rails uses for its filtered parameters.
    MASK = "[FILTERED]".freeze

    # Replaces a structure found again inside itself, which cannot be copied whole.
    CIRCULAR = "[FILTERED: circular]".freeze

    # Replaces a structure nested deeper than the formatters write (see Utils.json_safe), so that
    # walking it can never overflow the stack.
    NESTED_TOO_DEEPLY = "[FILTERED: nested too deeply]".freeze

    MAX_DEPTH = Utils::MAX_JSON_SAFE_DEPTH

    # A key name in snake_case already, which is not converted (see #snake_case_forms).
    SNAKE_CASE = /\A[a-z\d_]*\z/

    # How many keys the answer is remembered for (see #remember). Log entries use the same few keys
    # over and over, but the names of request parameters, for example, are chosen by whoever sends
    # the request, so neither how many nor how long they are is left to them.
    MAX_REMEMBERED_KEYS = 1_000

    # The longest key name, in characters, that the answer is remembered for (see #remember).
    MAX_REMEMBERED_KEY_LENGTH = 128

    # No snake_case forms of a key name, for one that is in snake_case already (see #snake_case_forms).
    EMPTY_FORMS = [].freeze
    private_constant :EMPTY_FORMS

    # Stands for a key not yet asked about in the remembered answers, in which nil means "not sensitive".
    UNKNOWN = Object.new.freeze
    private_constant :UNKNOWN

    # What the sensitive keys can be, for the error raised for any other value.
    EXPECTED = "an Array of Symbols, Strings, or Regexps, a Regexp, or an object that responds to " \
               "#filter_param (such as ActiveSupport::ParameterFilter) or #call".freeze
    private_constant :EXPECTED

    # Returns the sensitive keys, as supplied.
    attr_reader :sensitive_keys

    # Parameters
    #   sensitive_keys: [Array|Regexp|Object]
    #     Which keys are sensitive, one of:
    #     Array: Symbols and Strings, each matching any key name that contains it, ignoring case,
    #       as the Symbols in Rails' `config.filter_parameters` do, and Regexps.
    #     Regexp: Matches the sensitive key names.
    #     An object that responds to `#filter_param(key, value)`, such as
    #       ActiveSupport::ParameterFilter: given a key name and nil, it returns nil when the key is
    #       not sensitive, and otherwise the value that replaces the key's value.
    #     An object that responds to `#call(name)`, such as a Proc: given a key name, it returns
    #       whether the key is sensitive.
    #
    # The answer for each key is remembered (see #replacement_for), so the same key name must
    # always get the same answer.
    #
    # Raises ArgumentError for any other value.
    def initialize(sensitive_keys)
      @sensitive_keys = sensitive_keys
      @matcher        = matcher_for(sensitive_keys)
      @replacements   = Concurrent::Map.new
    end

    # Returns a copy of the value in which the value of every sensitive key is replaced, at any
    # depth, or the value itself when it has no sensitive key, so that what the formatters write
    # only changes when something is redacted. The exceptions are a structure that holds itself,
    # cut off with CIRCULAR, and one nested deeper than MAX_DEPTH, replaced with NESTED_TOO_DEEPLY.
    #
    # Looks inside the keys and values of the structures that the formatters write as JSON objects
    # and arrays (see Utils.structure?), such as a Hash, Array, Set, Struct, or Data, and inside an
    # object that responds to #to_unsafe_h, such as ActionController::Parameters. A copy is a Hash or
    # an Array, as they write it. Any other value is returned as it is. The value and the structures
    # in it are never changed, since they can be the application's own, or be shared by other log
    # entries, as named tags are.
    #
    # Never raises a StandardError: when the value cannot be redacted, such as when the sensitive
    # keys raise, it is replaced whole, and the error is reported to the internal logger.
    def redact(value)
      return value unless structure?(value)

      walk(value, {}.compare_by_identity, 0)
    rescue StandardError => e
      report(e)
      {redaction_failed: e.class.name || e.class.inspect}
    end

    # Returns the value that replaces the value of a sensitive key, or nil when the key is not
    # sensitive, or is neither a Symbol nor a String.
    #
    # The answer is remembered (see #remember), since asking the sensitive keys costs far more than
    # looking it up.
    def replacement_for(key)
      return unless key.is_a?(Symbol) || key.is_a?(String)

      replacement = @replacements.fetch(key, UNKNOWN)
      return replacement unless UNKNOWN.equal?(replacement)

      replacement = ask(key)
      remember(key, replacement)
      replacement
    end

    private

    # Returns [Proc] given a key name, the value that replaces a sensitive key's value, or nil.
    # Raises ArgumentError when the sensitive keys are not one of the values #initialize accepts.
    def matcher_for(sensitive_keys)
      case sensitive_keys
      when Array
        regexp_matcher(Regexp.union(sensitive_keys.map { |key| pattern_for(key) }))
      when Regexp
        regexp_matcher(sensitive_keys)
      else
        if sensitive_keys.respond_to?(:filter_param)
          # Or nil, so that a false answer is not taken for the replacement.
          ->(name) { sensitive_keys.filter_param(name, nil) || nil }
        elsif sensitive_keys.respond_to?(:call)
          ->(name) { MASK if sensitive_keys.call(name) }
        else
          raise(ArgumentError, "Expected sensitive keys as #{EXPECTED}, not #{sensitive_keys.inspect}")
        end
      end
    end

    def regexp_matcher(regexp)
      ->(name) { MASK if regexp.match?(name) }
    end

    # Returns [Regexp] the pattern for one of an Array of sensitive keys (see #initialize).
    def pattern_for(key)
      case key
      when Regexp
        key
      when Symbol, String
        Regexp.new(Regexp.escape(key.to_s), Regexp::IGNORECASE)
      else
        raise(ArgumentError, "Expected each sensitive key to be a Symbol, String, or Regexp, not #{key.inspect}")
      end
    end

    # Asks the sensitive keys about the key's name, and when that is not sensitive, about each of its
    # snake_case forms (see #snake_case_forms).
    def ask(key)
      name        = Utils.encode_utf8_string(key.is_a?(Symbol) ? key.name : key)
      replacement = @matcher.call(name)
      return replacement unless replacement.nil?

      snake_case_forms(name).each do |snake|
        replacement = @matcher.call(snake)
        return replacement unless replacement.nil?
      end
      nil
    end

    # Remembers the answer for the key, unless its name is longer than MAX_REMEMBERED_KEY_LENGTH.
    # When MAX_REMEMBERED_KEYS are already remembered, they are forgotten first, so that the keys
    # being logged now are remembered, rather than the first ones ever seen.
    def remember(key, replacement)
      return if key.length > MAX_REMEMBERED_KEY_LENGTH

      @replacements.clear if @replacements.size >= MAX_REMEMBERED_KEYS
      # A frozen copy of a String key that is not frozen, as a Hash keeps, so that changing the key
      # afterwards cannot change what it is remembered under.
      key = key.dup.freeze if key.is_a?(String) && !key.frozen?
      @replacements[key] = replacement
    end

    # Returns the redacted copy of the value, or the value itself when nothing in it is sensitive.
    #
    # seen maps each structure being walked, or already walked, to its result, so that a structure
    # held more than once is walked once, and one that holds itself is cut off rather than copied
    # with the original, unredacted, structure inside.
    def walk(value, seen, depth)
      return value unless structure?(value)

      if seen.key?(value)
        result = seen[value]
        return result.nil? ? CIRCULAR : result
      end
      return NESTED_TOO_DEEPLY if depth >= MAX_DEPTH

      seen[value] = nil # Until its result is known.
      seen[value] = walk_members(value, members_of(value), seen, depth)
    end

    def walk_members(value, members, seen, depth)
      if members.is_a?(Hash)
        walk_hash(value, members, seen, depth)
      elsif Utils.json_array?(value)
        walk_array(value, members, seen, depth)
      else
        # A #to_h, or #to_unsafe_h, that does not return a Hash is walked as a value of its own, one
        # level deeper, the way the formatters write it.
        redacted = walk(members, seen, depth + 1)
        redacted.equal?(members) ? value : redacted
      end
    end

    # Copies are only made from the first value that changes, since most entries have no sensitive
    # key, and the structures before it are kept.
    #
    # A key that is itself a structure, which the formatters write as its JSON, is redacted too.
    def walk_hash(value, members, seen, depth)
      copy  = nil
      index = 0
      members.each_pair do |key, val|
        new_key     = key.is_a?(Symbol) || key.is_a?(String) ? key : walk(key, seen, depth + 1)
        replacement = replacement_for(key)
        new_val     = replacement.nil? ? walk(val, seen, depth + 1) : replacement
        if copy
          copy[new_key] = new_val
        elsif !(new_val.equal?(val) && new_key.equal?(key))
          copy          = hash_head(members, index)
          copy[new_key] = new_val
        end
        index += 1
      end
      copy || value
    end

    # Returns [Hash] a new Hash with the first count pairs of the members.
    def hash_head(members, count)
      copy = members.compare_by_identity? ? {}.compare_by_identity : {}
      members.each_pair do |key, val|
        break if count.zero?

        copy[key] = val
        count    -= 1
      end
      copy
    end

    def walk_array(value, members, seen, depth)
      copy = nil
      members.each_with_index do |element, index|
        new_element = walk(element, seen, depth + 1)
        if copy
          copy << new_element
        elsif !new_element.equal?(element)
          copy = members.first(index) << new_element
        end
      end
      copy || value
    end

    # Whether the value is a structure that #walk looks inside: one that the formatters write as a
    # JSON object or array (see Utils.structure?), or an object that responds to #to_unsafe_h, such
    # as ActionController::Parameters, which they write with all of its parameters.
    def structure?(value)
      case value
      when String, Symbol, Integer, Float, NilClass, TrueClass, FalseClass
        # The most common values, ruled out before the slower checks.
        false
      else
        Utils.structure?(value) || value.respond_to?(:to_unsafe_h)
      end
    end

    # Returns the members of a structure (see #structure?), usually a Hash or an Array.
    def members_of(value)
      Utils.structure?(value) ? Utils.structure_members(value) : value.to_unsafe_h
    end

    # Returns [Array<String>] the key name in snake_case, in one or two forms, or none when it is
    # snake_case already: words split where a lower case letter or digit meets a capital, such as
    # "x_api_key" for "X-Api-Key", "api_key" for "apiKey", and "session_ids" for "sessionIDs"; and
    # when it differs, with a run of capitals also split before its last capital, so that an
    # acronym starts a word of its own, such as "api_key" for "APIKey" and "otp_code" for "OTPCode".
    # Asking about both means a plural acronym, which the second form splits into "session_i_ds", is
    # still matched by the first.
    #
    # Each pattern takes time in proportion to the length of the name, on JRuby too, since a key
    # name can be long and chosen by whoever sends a request.
    def snake_case_forms(name)
      return EMPTY_FORMS if SNAKE_CASE.match?(name)

      words    = name.gsub(/([a-z\d])([A-Z])/, '\1_\2')
      acronyms = words.gsub(/([A-Z\d])(?=[A-Z][a-z])/, '\1_')
      forms    = [to_snake_case(words)]
      forms << to_snake_case(acronyms) unless acronyms == words
      forms
    end

    def to_snake_case(words) = words.downcase.gsub(/[^a-z\d]+/, "_")

    # Reports an error raised while redacting to the internal logger. Only its class and where it
    # was raised: its message, or the exception given to the internal logger, could hold the data
    # being redacted.
    def report(exception)
      where = exception.backtrace&.first
      Logger.processor.logger.warn(
        "Redacting sensitive keys raised #{exception.class.inspect}" \
        "#{" (#{where})" if where}, so the value was replaced with :redaction_failed"
      )
    rescue StandardError
      nil
    end
  end
end
