module SemanticLogger
  # Log
  #
  #   Class to hold all log entry information
  #
  # level
  #   Log level of the supplied log call
  #   :trace, :debug, :info, :warn, :error, :fatal
  #
  # thread_name
  #   Name of the thread in which the logging call was called,
  #   or its object id when the thread has no name
  #
  # name
  #   Class name supplied to the logging instance
  #
  # message
  #   Text message to be logged
  #
  # payload
  #   Optional Hash or Ruby Exception object to be logged
  #
  # time
  #   The time at which the log entry was created
  #
  # duration
  #   The time taken to complete a measure call
  #
  # tags
  #   Any tags active on the thread when the log call was made
  #
  # level_index
  #   Internal index of the log level
  #
  # exception
  #   Ruby Exception object to log
  #
  # metric [Object]
  #   Object supplied when measure_x was called
  #
  # backtrace [Array<String>]
  #   The backtrace captured at source when the log level >= SemanticLogger.backtrace_level
  #
  # metric_amount [Numeric]
  #   Used for numeric or counter metrics.
  #   For example, the number of inquiries or, the amount purchased etc.
  #
  # context [Hash]
  #   Named contexts that were captured when the log entry was created.
  class Log
    # Keys passed in without a payload that will be extracted and the remainder passed into the payload.
    NON_PAYLOAD_KEYS = %i[message exception backtrace exception
                          duration min_duration
                          log_exception on_exception_level
                          metric metric_amount dimensions].freeze

    # Values accepted for the :log_exception argument.
    LOG_EXCEPTION_OPTIONS = %i[full partial none].freeze
    private_constant :LOG_EXCEPTION_OPTIONS

    # A finite real number, which #assign can compare with another one.
    REAL_NUMBER = ->(value) { value.is_a?(Numeric) && value.real? && value.finite? }
    private_constant :REAL_NUMBER

    # Checks that a value is valid for its argument, for the arguments that do not accept any value.
    # Any other value would make #assign, or the formatters, raise.
    ARGUMENT_VALIDATORS = {
      backtrace:          ->(value) { value.is_a?(Array) && value.all?(String) },
      duration:           REAL_NUMBER,
      min_duration:       REAL_NUMBER,
      metric_amount:      REAL_NUMBER,
      dimensions:         ->(value) { value.is_a?(Hash) },
      log_exception:      ->(value) { LOG_EXCEPTION_OPTIONS.include?(value) },
      on_exception_level: ->(value) { Levels.valid?(value) }
    }.freeze
    private_constant :ARGUMENT_VALIDATORS

    # Hash#key?, which unlike HashWithIndifferentAccess#key? only matches the exact Symbol key.
    HASH_KEY = Hash.instance_method(:key?)
    private_constant :HASH_KEY

    # Whether the value is accepted for the :log_exception argument of #assign.
    def self.log_exception_option?(value)
      value.nil? || LOG_EXCEPTION_OPTIONS.include?(value)
    end

    # Returns [String] the name that identifies the thread in a log entry: the thread's own name,
    # or its object id when it has none, which Ruby never reuses within a process.
    def self.thread_name_for(thread) = thread.name || thread.object_id.to_s

    attr_accessor :level, :level_index, :name, :message, :time, :duration,
                  :payload, :exception, :thread_name, :backtrace,
                  :tags, :named_tags, :context,
                  :metric, :metric_amount, :dimensions

    def initialize(name, level, index = nil)
      @level       = level
      @thread_name = Log.thread_name_for(Thread.current)
      @name        = name
      @time        = Time.now
      @tags        = SemanticLogger.tags
      @named_tags  = SemanticLogger.named_tags
      @level_index = index.nil? ? Levels.index(level) : index
    end

    # Assign named arguments to this log entry, supplying defaults where applicable
    #
    # Returns [true|false] whether this log entry should be logged
    #
    # Example:
    #   logger.info(name: 'value')
    def assign(message: nil,
               payload: nil,
               min_duration: 0.0,
               exception: nil,
               metric: nil,
               metric_amount: nil,
               duration: nil,
               backtrace: nil,
               log_exception: :full,
               on_exception_level: nil,
               dimensions: nil)
      self.message       = message
      self.payload       = payload
      self.duration      = duration
      self.metric        = metric
      self.metric_amount = metric_amount
      self.dimensions    = dimensions

      if exception
        unless exception.is_a?(Exception)
          exception = ArgumentError.new("Invalid value for logger exception: #{Utils.safe_inspect(exception)}")
          exception.set_backtrace(Utils.extract_backtrace(caller))
        end

        case log_exception
        when :full
          self.exception = exception
        when :partial
          self.message = "#{message} -- Exception: #{exception.class}: #{exception.message}"
        when nil, :none
          # Log the message without the exception that was raised
          nil
        else
          raise(ArgumentError, "Invalid value:#{log_exception.inspect} for argument :log_exception")
        end
        # On exception change the log level
        if on_exception_level
          # Normalized through the index, so that a level supplied as a String or an Integer is
          # still stored as its Symbol.
          self.level_index = Levels.index(on_exception_level)
          self.level       = Levels.level(level_index)
        end
      end

      # Elastic logging: Log when :duration exceeds :min_duration
      # Except if there is an exception when it will always be logged
      return false if duration && (duration < min_duration) && exception.nil?

      if backtrace
        self.backtrace = Utils.extract_backtrace(backtrace)
      elsif level_index >= SemanticLogger.backtrace_level_index
        self.backtrace = Utils.extract_backtrace(caller)
      end

      true
    end

    # Log attributes that a Hash returned by a logging block can set (see #assign_hash). Its other
    # keys go to the payload, so that it cannot set fields such as :level, :name, or :time.
    ASSIGNABLE_KEYS = %i[message exception backtrace duration metric metric_amount dimensions].freeze

    # Assign the Hash returned by a logging block, after #assign has applied the log call.
    #
    # A block can return untrusted data, such as a parsed request body, so its keys are classified
    # by #extract_arguments, as for a Hash passed after the message. A log argument is only assigned
    # when this entry does not have it yet (an exception must also be an Exception), and otherwise
    # goes to the payload like any other key. Whatever the key order, the log call's values win,
    # then the block's top-level keys, then those of its :payload. No supplied Hash is modified.
    def assign_hash(hash)
      args           = extract_arguments(hash)
      added          = args.delete(:payload)
      assigned, kept = args.partition { |key, value| block_attribute?(key, value) }
      assigned.each { |key, value| public_send(:"#{key}=", value) }
      # An argument this entry already has wins over the block's :payload, like the block's other keys.
      added        = merge_payload(kept.to_h, added) unless kept.empty?
      self.payload = merge_payload(payload, added)
      self
    end

    # Returns [true|false] whether the value can be used as the log argument named by the key.
    #
    # Never raises, so it can check values from untrusted data before they are passed to #assign.
    # A nil value is never an argument, since it means the argument was not supplied. Arguments
    # without a validator in ARGUMENT_VALIDATORS (such as :message, :metric, or :exception, which
    # #assign logs as an ArgumentError when it is not an Exception) accept any other value.
    def self.argument?(key, value)
      return false if value.nil? || !NON_PAYLOAD_KEYS.include?(key)

      validator = ARGUMENT_VALIDATORS[key]
      validator.nil? || validator.call(value)
    end

    # Extract the arguments from a Hash Payload
    #
    # The hash can hold untrusted data, so this never fails because of its content: keys that are
    # not log attributes, or that hold a value that is not valid for it (see .argument?), are kept
    # in the payload. A log attribute key with a nil value counts as not supplied, so #assign uses
    # its default. When the hash supplies an explicit :payload, any other keys are merged into it,
    # and win over its values of the same name, since the explicit payload is where untrusted data
    # goes (see docs/security.md).
    def extract_arguments(payload, message = nil)
      raise(ArgumentError, "payload must be a Hash") unless payload.is_a?(Hash)

      message     = nil if message == ""
      explicit    = HASH_KEY.bind_call(payload, :payload)
      new_payload = {}
      args        = {}
      payload.each_pair do |key, value|
        if explicit && key == :payload
          args[:payload] = value
        elsif key == :message && !message.nil?
          # Supplied message takes precedence
          new_payload[key] = value unless explicit
        elsif Log.argument?(key, value)
          args[key] = value
        elsif value.nil? && NON_PAYLOAD_KEYS.include?(key)
          # Not supplied, so #assign uses its default
          next
        else
          new_payload[key] = value
        end
      end
      unless new_payload.empty?
        args[:payload] = explicit ? merge_payload(new_payload, args[:payload]) : new_payload
      end
      args[:message] = message if message
      args
    end

    MAX_EXCEPTIONS_TO_UNWRAP = 5
    # Call the block for exception and any nested exception
    def each_exception
      # With thanks to https://github.com/bugsnag/bugsnag-ruby/blob/6348306e44323eee347896843d16c690cd7c4362/lib/bugsnag/notification.rb#L81
      depth      = 0
      exceptions = []
      ex         = exception
      while !ex.nil? && !exceptions.include?(ex) && exceptions.length < MAX_EXCEPTIONS_TO_UNWRAP
        exceptions << ex
        yield(ex, depth)

        depth += 1
        ex    =
          if ex.respond_to?(:cause) && ex.cause
            ex.cause
          elsif ex.respond_to?(:continued_exception) && ex.continued_exception
            ex.continued_exception
          elsif ex.respond_to?(:original_exception) && ex.original_exception
            ex.original_exception
          end
      end
    end

    # Returns [String] the detail that Ruby's Exception#detailed_message adds to the message of the
    # supplied exception, without the class name that Ruby also adds. Since Ruby 3.2 this is where
    # did_you_mean suggestions ("Did you mean?  upcase") and the detail an exception class supplies
    # by overriding #detailed_message appear, rather than in #message.
    # Returns nil when there is no detail.
    #
    # Parameters
    #   exception: [Exception]
    #     This entry's exception, or one of its causes (see #each_exception).
    #   source: [true|false]
    #     Whether to include error_highlight's snippet of the failing source line, for example
    #     "user_name.upcas" with "^^^^^^" under the unknown method. It re-parses that source
    #     file on every call, so it is about 100 times slower, and it copies source code into
    #     the log.
    #     Default: false
    #
    # The result is cached on this entry, since every appender's formatter may ask for it.
    def exception_details(exception, source: false)
      key   = [exception, source]
      cache = @exception_details
      return cache[key] if cache&.key?(key)

      details = ExceptionDetails.extract(exception, source: source)
      # Replace the cache rather than change it, since appenders on other threads may be reading it.
      @exception_details = (cache || {}).merge(key => details).freeze
      details
    end

    # Returns [String] the exception backtrace including all of the child / caused by exceptions
    #
    # When a block is supplied, each cause's message and each backtrace line is passed
    # to it, and the value it returns is written in its place. This lets a caller, for
    # example a formatter, transform that text while this method keeps the layout.
    #
    # Example:
    #   log.backtrace_to_s { |text| text.gsub("\n", "\\n") }
    def backtrace_to_s(&block)
      trace = ""
      each_exception do |exception, i|
        lines = exception.backtrace || []
        lines = lines.map(&block) if block
        if i.zero?
          trace = lines.join("\n")
        else
          message = block ? yield(exception.message) : exception.message
          trace << "\nCause: #{exception.class.name}: #{message}\n#{lines.join("\n")}"
        end
      end
      trace
    end

    # Returns [String] duration of the log entry as a string
    # Returns nil if their is no duration
    # Java time precision does not include microseconds
    if Formatters::Base::PRECISION == 3
      def duration_to_s
        "#{duration.to_i}ms" if duration
      end
    else
      def duration_to_s
        return unless duration

        duration < 10.0 ? "#{format('%.3f', duration)}ms" : "#{format('%.1f', duration)}ms"
      end
    end

    # Returns [String] the duration in human readable form
    def duration_human
      return nil unless duration

      seconds = duration / 1000
      if seconds >= 86_400.0 # 1 day
        "#{(seconds / 86_400).to_i}d #{Time.at(seconds).utc.strftime('%-Hh %-Mm')}"
      elsif seconds >= 3600.0 # 1 hour
        Time.at(seconds).utc.strftime("%-Hh %-Mm")
      elsif seconds >= 60.0 # 1 minute
        Time.at(seconds).utc.strftime("%-Mm %-Ss")
      elsif seconds >= 1.0 # 1 second
        "#{format('%.3f', seconds)}s"
      else
        duration_to_s
      end
    end

    # Returns [String] single character upper case log level
    def level_to_s
      level.to_s[0..0].upcase
    end

    # DEPRECATED
    def process_info(thread_name_length = 30)
      file, line = file_name_and_line(true)
      file_name  = " #{file}:#{line}" if file

      "#{$$}:#{format("%.#{thread_name_length}s", thread_name)}#{file_name}"
    end

    CALLER_REGEXP = /^(.*):(\d+).*/

    # Extract the filename and line number from the last entry in the supplied backtrace
    def extract_file_and_line(stack, short_name = false)
      return unless stack&.size&.positive?

      match = CALLER_REGEXP.match(stack.first)
      return unless match

      [short_name ? File.basename(match[1]) : match[1], match[2].to_i]
    end

    # Returns [String, String] the file_name and line_number from the backtrace supplied
    # in either the backtrace or exception
    def file_name_and_line(short_name = false)
      stack = backtrace || exception&.backtrace
      extract_file_and_line(stack, short_name)
    end

    # Strip the standard Rails colorizing from the logged message.
    #
    # Note: This unconditionally *strips* ANSI colorization, and is used to keep
    # terminal escape codes out of structured (JSON/Loki) output. It is distinct
    # from Formatters::Base#escape_control_characters, which instead *escapes*
    # (preserves) control characters and is opt-in for the text formatters.
    #
    # A message tagged UTF-8 can hold invalid bytes, for example a request parameter that Rack
    # decoded from "%FF", or be in another encoding, such as a binary request body. Stripping or
    # matching such a String raises, so it is converted to valid UTF-8 first, dropping the
    # invalid bytes, as the JSON formatters do.
    def cleansed_message
      msg = Utils.encode_utf8_string(message.to_s)
      return msg.strip unless msg.include?("\e")

      msg.gsub(/\e\[[\d;]*[mz]?|\e/, "").strip
    end

    # Return the payload in text form
    # Returns nil if payload is missing or empty
    #
    # Rendered with #inspect, or with the block when given (for example Amazing Print). A payload
    # nested too deeply for either is first cut off at Utils::MAX_JSON_SAFE_DEPTH, rather than
    # raising SystemStackError (see Utils.safe_inspect).
    def payload_to_s(&)
      Utils.safe_inspect(payload, &) if payload?
    end

    # Returns [true|false] whether the log entry has a payload
    def payload?
      !(payload.nil? || (payload.respond_to?(:empty?) && payload.empty?))
    end

    def to_h(host = SemanticLogger.host, application = SemanticLogger.application,
             environment = SemanticLogger.environment)
      logger = Struct.new(:host, :application, :environment).new(host, application, environment)
      SemanticLogger::Formatters::Raw.new.call(self, logger)
    end

    # Lazy initializes the context hash and assigns a key value pair.
    def set_context(key, value)
      (self.context ||= {})[key] = value
    end

    # A metric only event has a metric but no message or exception.
    def metric_only?
      metric && message.nil? && exception.nil?
    end

    private

    # Returns the kept payload with the keys of the added one that it does not have, so that a kept
    # value is never replaced. A String and a Symbol key of the same name, such as "account_id" from
    # JSON.parse and :account_id, count as the same key, since the formatters write both under that
    # name. A payload that is not a Hash is kept as its :payload key, but the kept payload is
    # returned unchanged when there is nothing to add. Neither payload is modified.
    def merge_payload(kept, added)
      added = {payload: added} unless added.nil? || added.is_a?(Hash)
      return kept if added.nil? || added.empty?

      kept = {payload: kept} unless kept.nil? || kept.is_a?(Hash)
      return added if kept.nil? || kept.empty?

      merged = kept.merge(added) { |_key, kept_value, _added_value| kept_value }
      # Only the kept keys, usually a few supplied by the application, are checked one at a time.
      kept.each_key do |key|
        next unless key.is_a?(Symbol) || key.is_a?(String)

        other = key.is_a?(Symbol) ? key.name : key.to_sym
        merged.delete(other) unless kept.key?(other)
      end
      merged
    end

    # Whether a log argument from the Hash returned by a logging block, already checked by
    # .argument?, is assigned to its attribute: only when this entry does not have it yet. As in
    # #extract_arguments, an empty message counts as none.
    def block_attribute?(key, value)
      return message.nil? || message == "" if key == :message
      return exception.nil? && value.is_a?(Exception) if key == :exception

      ASSIGNABLE_KEYS.include?(key) && public_send(key).nil?
    end
  end
end
