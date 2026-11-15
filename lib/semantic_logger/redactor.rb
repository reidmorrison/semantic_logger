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

    # A key name in snake_case already, which is not converted (see #snake_case).
    SNAKE_CASE = /\A[a-z\d_]*\z/

    # How many keys the answer is remembered for (see #replacement_for). Log entries use the same few
    # keys over and over, but the names of request parameters, for example, are chosen by whoever
    # sends the request, so the number remembered is capped.
    MAX_REMEMBERED_KEYS = 1_000

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
    # only changes when something is redacted.
    #
    # Looks inside a Hash, Array, Set, Struct, Data, OpenStruct, or an object that responds to
    # #to_unsafe_h, such as ActionController::Parameters, the structures that the formatters write
    # as JSON objects and arrays. A copy is a Hash or an Array, as they write it. Any other value is
    # returned as it is. The value and the structures in it are never changed, since they can be
    # the application's own, or be shared by other log entries, as named tags are.
    #
    # Never raises a StandardError: when the value cannot be redacted, such as when the sensitive
    # keys raise, it is replaced whole, and the error is reported to the internal logger.
    def redact(value)
      walk(value, {}.compare_by_identity, 0)
    rescue StandardError => e
      report(e)
      {redaction_failed: e.class.name || e.class.inspect}
    end

    # Returns the value that replaces the value of a sensitive key, or nil when the key is not
    # sensitive, or is neither a Symbol nor a String.
    #
    # The answer is remembered for up to MAX_REMEMBERED_KEYS keys, since asking the sensitive keys
    # costs far more than looking it up.
    def replacement_for(key)
      return unless key.is_a?(Symbol) || key.is_a?(String)

      replacement = @replacements.fetch(key, UNKNOWN)
      return replacement unless UNKNOWN.equal?(replacement)

      replacement = ask(key)
      @replacements[key] = replacement if @replacements.size < MAX_REMEMBERED_KEYS
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

    # Asks the sensitive keys about the key's name, and when that is not sensitive, about its name
    # in snake_case.
    def ask(key)
      name        = Utils.encode_utf8_string(key.is_a?(Symbol) ? key.name : key)
      replacement = @matcher.call(name)
      return replacement unless replacement.nil?

      snake = snake_case(name)
      @matcher.call(snake) unless snake.equal?(name)
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
      members     = members_of(value)
      seen[value] =
        if members.is_a?(Hash)
          walk_hash(value, members, seen, depth)
        else
          walk_array(value, members, seen, depth)
        end
    end

    # Copies are only made from the first value that changes, since most entries have no sensitive
    # key, and the structures before it are kept.
    def walk_hash(value, members, seen, depth)
      copy  = nil
      index = 0
      members.each_pair do |key, val|
        replacement = replacement_for(key)
        new_val     = replacement.nil? ? walk(val, seen, depth + 1) : replacement
        if copy
          copy[key] = new_val
        elsif !new_val.equal?(val)
          copy      = hash_head(members, index)
          copy[key] = new_val
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

    # Whether the value is a structure that #walk looks inside (see #redact).
    def structure?(value)
      case value
      when String, Symbol, Integer, Float, NilClass, TrueClass, FalseClass
        # The most common values, ruled out before the slower checks below.
        false
      when Hash, Array, ::Set, Struct, ::Data
        true
      else
        Utils.structure?(value) || value.respond_to?(:to_unsafe_h)
      end
    end

    # Returns [Hash|Array] the members of a structure (see #structure?).
    def members_of(value)
      case value
      when Hash, Array
        value
      when ::Set
        value.to_a
      else
        members = value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h
        # A #to_h that returns something else is walked as a single element, as the formatters do.
        members.is_a?(Hash) ? members : [members]
      end
    end

    # Returns [String] the key name in snake_case, such as "x_api_key" for "X-Api-Key" and
    # "api_key" for "apiKey", or the same name when it is already.
    def snake_case(name)
      return name if SNAKE_CASE.match?(name)

      name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.gsub(/[^a-z\d]+/, "_")
    end

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
