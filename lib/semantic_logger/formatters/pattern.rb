require "time"

module SemanticLogger
  module Formatters
    # Formats log messages using a configurable pattern string, so a custom
    # log line layout can be specified directly in the configuration without
    # having to write a new formatter class.
    #
    # Pattern placeholders use the form `%{directive}`, where `directive` is the
    # name of any of the formatting methods (inherited from Default, or defined
    # below). Named tags support a parameterized form: `%{named_tags:request_id}`
    # returns the value of a single named tag. Use `%%{...}` to emit a literal
    # `%{...}` without interpolation.
    #
    # Example:
    #   SemanticLogger.add_appender(
    #     io:        $stdout,
    #     formatter: {
    #       pattern: { pattern: "%{time} %{level} %{name} -- %{message}" }
    #     }
    #   )
    #
    # Available directives:
    #   time                 Formatted timestamp.
    #   level                Full level name, e.g. "debug".
    #   level_short          Single character level, e.g. "D".
    #   name                 Logger / class name.
    #   message              Log message.
    #   payload              Payload rendered as a string.
    #   exception_class      Class of the logged exception, e.g. "RuntimeError".
    #   exception_message    Message of the logged exception.
    #   backtrace            Backtrace of the logged exception.
    #   duration             Human readable duration, e.g. "1.2ms".
    #   duration_ms          Duration in milliseconds (numeric).
    #   thread_name          Name of the thread that logged the message.
    #   pid                  Process id.
    #   file_name            Ruby file name that logged the message, e.g. "app.rb".
    #   line                 Line number within the Ruby file, e.g. 42.
    #   tags                 Tags, comma separated.
    #   named_tags           All named tags, or one tag with named_tags:key.
    #   host                 Host name.
    #   application          Application name.
    #   environment          Environment name.
    class Pattern < Default
      attr_reader :pattern

      # Approximates the Default formatter's output.
      DEFAULT_PATTERN = "%{time} %{level} [%{pid}:%{thread_name}] %{name} -- %{message}".freeze

      # The directives that may appear in a pattern. The value is whether the
      # directive accepts a parameter, e.g. %{named_tags:request_id}.
      DIRECTIVES = {
        time:              false,
        level:             false,
        level_short:       false,
        name:              false,
        message:           false,
        payload:           false,
        exception_class:   false,
        exception_message: false,
        backtrace:         false,
        duration:          false,
        duration_ms:       false,
        thread_name:       false,
        pid:               false,
        file_name:         false,
        line:              false,
        tags:              false,
        named_tags:        true,
        host:              false,
        application:       false,
        environment:       false
      }.freeze

      # A single interpolated directive within a compiled pattern.
      Token = Struct.new(:method_name, :arguments)
      private_constant :Token

      # Parameters:
      #   pattern: [String]
      #     The pattern string used to format every log entry.
      #     Default: DEFAULT_PATTERN
      #
      # Plus all the options supported by SemanticLogger::Formatters::Base.
      def initialize(pattern: DEFAULT_PATTERN, **args)
        @pattern = pattern
        super(**args)
        # Parse the pattern once, up front, so that formatting every log entry
        # is just a walk over the pre-compiled tokens (no regex on the hot path).
        # Unknown directives raise here, at configuration time, not per log.
        @tokens = compile(pattern)
      end

      # Full level name, e.g. "debug" (Default formatter uses the short "D").
      def level
        log.level.to_s
      end

      # Single character level, e.g. "D".
      def level_short
        log.level_to_s
      end

      # Log message (without the "-- " prefix the Default formatter adds).
      def message
        escape_control_characters(log.message)
      end

      # Raw payload rendered as a string.
      def payload
        log.payload_to_s
      end

      # Class of the logged exception, e.g. "RuntimeError".
      def exception_class
        log.exception&.class
      end

      # Message of the logged exception.
      def exception_message
        escape_control_characters(log.exception&.message)
      end

      # Backtrace of the logged exception.
      def backtrace
        log.backtrace_to_s if log.exception
      end

      # Human readable duration (without the Default formatter's surrounding parentheses).
      def duration
        log.duration_human
      end

      # Duration in milliseconds.
      def duration_ms
        log.duration
      end

      # Name of the Ruby file that logged the message, e.g. "app.rb".
      def file_name
        log.file_name_and_line(true)&.first
      end

      # Line number within the Ruby file that logged the message.
      def line
        log.file_name_and_line(true)&.last
      end

      # Tags joined by a comma (without the Default formatter's surrounding brackets).
      def tags
        return if log.tags.nil? || log.tags.empty?

        log.tags.map { |tag| escape_control_characters(tag) }.join(", ")
      end

      # With a key: the value of a single named tag, e.g. %{named_tags:request_id}.
      # Without a key: all named tags rendered as "key: value, ...".
      def named_tags(key = nil)
        named = log.named_tags
        return if named.nil? || named.empty?

        if key
          escape_control_characters(named[key.to_sym] || named[key.to_s])
        else
          named.map { |name, value| "#{escape_control_characters(name)}: #{escape_control_characters(value)}" }.join(", ")
        end
      end

      # Host name.
      def host
        logger&.host if log_host
      end

      # Application name.
      def application
        logger&.application if log_application
      end

      # Environment name.
      def environment
        logger&.environment if log_environment
      end

      def call(log, logger)
        self.log    = log
        self.logger = logger

        @tokens.each_with_object(+"") do |token, out|
          out << (token.is_a?(Token) ? public_send(token.method_name, *token.arguments).to_s : token)
        end
      end

      private

      # Parse the pattern string into an array of tokens: frozen literal strings
      # and Token structs for each %{directive} placeholder. %%{...} is an escape
      # that produces a literal %{...}.
      def compile(string)
        tokens = []
        pos    = 0

        string.scan(/%%?\{[^}]+\}/) do |match|
          current = Regexp.last_match
          tokens << string[pos...current.begin(0)].freeze if current.begin(0) > pos

          if match.start_with?("%%")
            tokens << match[1..].freeze
          else
            name, arg = match[/\{([^}]+)\}/, 1].split(":", 2)
            name      = name.strip.to_sym
            raise(ArgumentError, "Invalid pattern directive: %{#{name}}") unless DIRECTIVES.key?(name)
            raise(ArgumentError, "%{#{name}} does not accept an argument") if arg && !DIRECTIVES[name]

            tokens << Token.new(name, arg ? [arg.strip] : []).freeze
          end

          pos = current.end(0)
        end

        tokens << string[pos..].freeze if pos < string.length
        tokens
      end
    end
  end
end
