module SemanticLogger
  # Where a log entry was logged: the path and line of the code that made the log call, and the
  # label of its frame, usually the method, such as "Order#submit".
  #
  # Log#assign sets it when the entry's level is at or above SemanticLogger.call_site_level. When the
  # log call supplies a backtrace, the call site is its first line. Otherwise it is the first frame of
  # the calling thread's stack outside Semantic Logger and SemanticLogger.call_site_skip_paths, which
  # costs far less than capturing a backtrace, since only the frames up to it are read.
  #
  # A call site is frozen and holds only frozen Strings and an Integer, so that a log entry logged in
  # another Ractor can be sent to the main one.
  #
  # Attributes:
  #   path: [String]
  #     The file, as in a backtrace, such as "/app/models/order.rb".
  #   line: [Integer]
  #     The line number in the file.
  #   label: [String|nil]
  #     The label of the frame, as in a backtrace. On Ruby 3.4 and later it includes the class, such
  #     as "Order#submit" or "Order.find_open", on Ruby 3.2 and 3.3 only the method, such as "submit".
  #     A block's label starts with "block in", and code outside a method has a label such as
  #     "<main>" or "<class:Order>".
  CallSite = Data.define(:path, :line, :label)

  class CallSite
    # The number of frames read from the stack at a time. Semantic Logger's own frames, which are
    # skipped, are usually fewer than this.
    WINDOW = 8
    private_constant :WINDOW

    # Paths of the frames of Ruby's own methods written in Ruby, such as "<internal:kernel>", which are
    # never the code that logged the entry. Which methods these are depends on the version of Ruby.
    INTERNAL_PATH = "<internal:".freeze
    private_constant :INTERNAL_PATH

    # Labels of Ruby's methods that call a method for their caller, such as
    # `logger.public_send(level, message)`, and add a frame of their own with the caller's path and
    # line.
    #
    # CRuby 3.4 and later include the class in the label, which tells these methods apart from an
    # application's own methods of the same name. JRuby, and CRuby before 3.4, do not, so there an
    # application's own `call` method is also skipped when it was called from the same line of the
    # same file, such as by recursion or a one-line definition. The path and line stay the same; only
    # the label becomes the caller's. JRuby labels the frame "block in public_send" when it is called
    # in a block. "block in call" is left out, since it is also the label of a block in an
    # application's own `call` method.
    DISPATCH_LABELS = Utils.make_shareable(
      if RUBY_ENGINE == "ruby" && RUBY_VERSION >= "3.4"
        %w[Kernel#public_send Method#call UnboundMethod#bind_call].freeze
      else
        ["public_send", "call", "bind_call", "block in public_send", "block in bind_call"].freeze
      end
    )
    private_constant :DISPATCH_LABELS

    # The line number and the start of the label in a backtrace line, such as ":12:in 'Order#submit'",
    # or as Ruby 3.3 and earlier write it, ":12:in `submit'". Without a leading `.*`, so that matching an
    # untrusted line takes linear time on every Ruby, including JRuby, which has no backtracking limits.
    # A line number has at most 10 digits, since a longer one, which only a forged line has, would be
    # slow to convert to an Integer and back.
    LINE_AND_LABEL = /:(\d{1,10}):in [`']/
    private_constant :LINE_AND_LABEL

    # A backtrace line without a label, such as "app.rb:12".
    UNLABELED_LINE = /\A(.+):(\d{1,10})(?!\d)/
    private_constant :UNLABELED_LINE

    # A line break, which only a forged backtrace line holds.
    LINE_BREAK = "\n".freeze
    private_constant :LINE_BREAK

    # A label's closing quote.
    QUOTE = "'".freeze
    private_constant :QUOTE

    # Returns [CallSite|nil] where a log entry was logged, from what the log call supplied:
    #   call_site: [CallSite|Thread::Backtrace::Location|false|nil]
    #     The call site, or the frame it is made from. false: the entry has no call site.
    #   backtrace: [Array<String>|nil]
    #     Without a call site, its first line is the call site.
    # Without either (or with an empty backtrace), the first frame of the calling thread's stack
    # outside Semantic Logger (see .capture).
    def self.locate(call_site: nil, backtrace: nil)
      return if call_site == false
      return from(call_site) if call_site

      backtrace.nil? || backtrace.empty? ? capture : parse(backtrace.first)
    end

    # Returns [CallSite] the call site, or the call site of a Thread::Backtrace::Location.
    def self.from(call_site)
      return call_site if call_site.is_a?(CallSite)

      label = call_site.label
      new(-call_site.path, call_site.lineno, label && -label)
    end

    # Whether the value can be supplied as a log entry's call site (see .locate). A value that parsed
    # data, such as JSON, can hold is not, other than false, so that untrusted data cannot set the
    # location of an entry.
    def self.supplied?(value)
      value == false || value.is_a?(CallSite) || value.is_a?(::Thread::Backtrace::Location)
    end

    # Returns [CallSite|nil] the first frame of the calling thread's stack outside Semantic Logger, Ruby's
    # own methods, and SemanticLogger.call_site_skip_paths, and other than the frame of a method such
    # as public_send that called the logger for it. nil when every frame is skipped.
    def self.capture
      skip_paths = SemanticLogger.call_site_skip_paths
      # A Ractor other than the main one cannot use the main Ractor's cache.
      cache      = RactorSupport.other_ractor? ? nil : skip_cache(skip_paths)
      start      = 1
      # One frame more than the window, which is only read as the caller of the frame before it.
      # caller_locations returns nil, or on JRuby an empty Array, once start is past the end of the stack.
      while (locations = caller_locations(start, WINDOW + 1)) && !locations.empty?
        locations.each_with_index do |location, index|
          break if index == WINDOW

          path = location.path
          next if skip?(path, skip_paths, cache)

          label = location.label
          next if dispatch?(location, label, locations[index + 1])

          return new(-path, location.lineno, label && -label)
        end
        start += WINDOW
      end
    end

    # Returns [CallSite|nil] the call site in a line of a backtrace, such as
    # "app.rb:12:in 'Order#submit'". nil when the line is not a String with a path and line number,
    # or is not text that Ruby can match, such as invalid UTF-8.
    def self.parse(line)
      return unless line.is_a?(String) && line.encoding.ascii_compatible? && line.valid_encoding?
      return if line.include?(LINE_BREAK)

      # The first ":12:in '" is the end of the path, since a label can hold anything. The label's
      # closing quote must follow its opening one.
      match = LINE_AND_LABEL.match(line) if line.end_with?(QUOTE)
      if match&.begin(0)&.positive? && match.end(0) < line.size
        return new(-match.pre_match, match[1].to_i, -line[match.end(0)...-1])
      end

      match = UNLABELED_LINE.match(line)
      new(-match[1], match[2].to_i, nil) if match
    end

    # Whether a frame in the file at this path is skipped when capturing a call site.
    #
    # The frames of log calls come from a few files, Semantic Logger's own and the application's, so
    # the answer is remembered in the cache for each path, which is faster than matching the path
    # again. Without a cache, the path is matched each time.
    def self.skip?(path, skip_paths, cache)
      return skip_path?(path, skip_paths) unless cache

      skipped = cache[path]
      return skipped unless skipped.nil?

      # Bounded, since code evaluated at runtime can have a path of its own each time.
      cache.clear if cache.size >= MAX_CACHED_PATHS
      cache[path] = skip_path?(path, skip_paths)
    end
    private_class_method :skip?

    # The most paths whose answer .skip? remembers.
    MAX_CACHED_PATHS = 1_000
    private_constant :MAX_CACHED_PATHS

    # Returns [Concurrent::Map] whether each path is skipped, for these skip paths. A new one when the
    # skip paths have changed.
    def self.skip_cache(skip_paths)
      cache = @skip_cache
      return cache.last if cache&.first.equal?(skip_paths)

      (@skip_cache = [skip_paths, Concurrent::Map.new]).last
    end
    private_class_method :skip_cache

    # Whether the frame is that of a method such as public_send, called by the frame after it, which
    # has the same path and line. Then the frame after it made the log call.
    def self.dispatch?(location, label, caller_location)
      DISPATCH_LABELS.include?(label) && !caller_location.nil? &&
        caller_location.lineno == location.lineno && caller_location.path == location.path
    end
    private_class_method :dispatch?

    def self.skip_path?(path, skip_paths)
      return true if path.start_with?(INTERNAL_PATH) || Utils.extract_path?(path)

      skip_paths.any? { |skip_path| path.include?(skip_path) }
    end
    private_class_method :skip_path?

    # Returns [Array<String, Integer>] the file name and line number of the call site. With short_name
    # the file name has no directory, such as "order.rb".
    def file_name_and_line(short_name: false)
      [short_name ? File.basename(path) : path, line]
    end

    # Returns [String] the call site as Ruby 3.4 and later write it in a backtrace, such as
    # "/app/models/order.rb:42:in 'Order#submit'".
    def to_s
      label ? "#{path}:#{line}:in '#{label}'" : "#{path}:#{line}"
    end
  end
end
