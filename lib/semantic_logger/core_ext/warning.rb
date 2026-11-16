require "json"

module SemanticLogger
  module CoreExt
    # Drops the json gem's warning about a binary String when Semantic Logger serializes log data.
    #
    # json 2.8.0 through 3.0.x write a binary String that holds valid UTF-8 outside ASCII as
    # UTF-8, but warn "JSON.generate: UTF-8 string passed as BINARY, this will raise an encoding
    # error in json 3.0" for each one, every time, at the default verbosity. Log data often holds
    # such Strings: response bodies, Base64-decoded text, socket reads. The JSON is right: json 3.1
    # raises instead, and Utils.to_json then writes the same String as the same UTF-8 (see
    # Utils.json_safe). So for log data the warning only reports what Semantic Logger handles.
    #
    # Finding the binary Strings before serializing would mean walking every log entry, which
    # takes longer than serializing it, and marking each serialization would slow every entry
    # too. Instead, when the warning is raised, Utils is asked whether it comes from serializing
    # log data (see Utils.serializing_log_data?). Only a warning pays for that.
    #
    # Prepended to `Warning` when Semantic Logger is loaded on CRuby with json 2.8.0 through 3.0.x
    # (see NEEDED), so that it sees the warning before a `Warning.warn` that the application
    # defines on `Warning`, extends into it, or prepends to it before loading Semantic Logger. A
    # module prepended afterwards, such as a test helper that raises on warnings, sees it first.
    # Any other warning, and this one from anywhere else, such as the application's own JSON, is
    # passed on unchanged.
    module Warning
      # Part of the warning, which json 2.8.0 through 3.0.x prefix with "JSON.generate: ".
      BINARY_STRING = "UTF-8 string passed as BINARY".freeze

      # Whether this json gem warns about a binary String: the C extension of json 2.8.0 through
      # 3.0.x. JRuby's json, and json 3.1 and later, raise instead.
      NEEDED = RUBY_ENGINE == "ruby" &&
               JSON::VERSION.split(".").first(2).map(&:to_i).then do |version|
                 (version <=> [2, 8]) >= 0 && (version <=> [3, 1]).negative?
               end

      # Key of the fiber-local state of .unless_binary_string_warned: :watching while it runs, and
      # :warned once the warning was dropped meanwhile.
      STATE = :semantic_logger_json_warning

      # Returns the block's result, or nil when the json gem warned about a binary String while
      # it ran, for a caller that hands the data on to be serialized elsewhere and so has to repair
      # it (see Utils.json_ready).
      def self.unless_binary_string_warned
        return yield unless NEEDED

        previous = Thread.current[STATE]
        Thread.current[STATE] = :watching
        result = yield
        result unless Thread.current[STATE] == :warned
      ensure
        Thread.current[STATE] = previous if NEEDED
      end

      # Called by Ruby for each warning. Drops the json gem's binary String warning when it comes
      # from Semantic Logger serializing log data, noting it for .unless_binary_string_warned;
      # passes on every other warning.
      #
      # The category is passed on only to a #warn that accepts it, as Ruby itself does, so that a
      # `Warning.warn(message)` of the application's own keeps working.
      def warn(message, *, **)
        if message.is_a?(String) && message.include?(BINARY_STRING) && Utils.serializing_log_data?
          Thread.current[STATE] = :warned if Thread.current[STATE]
          return
        end

        Warning.instance_method(:warn).bind(self).super_method.arity == 1 ? super(message) : super
      end
    end
  end
end
