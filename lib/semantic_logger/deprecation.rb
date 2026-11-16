require "rbconfig"

module SemanticLogger
  # Reports the use of a deprecated method or option as a Ruby deprecation warning, see `Kernel#warn`, so that Ruby
  # decides whether and where it is reported, as it does for its own deprecations, rather than a setting of Semantic
  # Logger:
  # - Only while deprecation warnings are on, see `Warning[:deprecated]`. They are off by default, so production stays
  #   quiet, and on in tests run by Minitest or test-unit, or with `ruby -W:deprecated` or `RUBYOPT=-W:deprecated`.
  # - Written to `$stderr`, unless the application routes them elsewhere, such as to its log, or raises them in its
  #   tests, by overriding `Warning.warn`.
  #
  # Each warning names the line of the application that used what is deprecated, rather than a line of Semantic
  # Logger, of Ruby itself, or of a gem that Semantic Logger called with a block, see .application_location.
  #
  # Copied from IOStreams::Deprecation, so that both libraries report deprecations the same way.
  module Deprecation
    # The directory of the files of this library, whose lines are skipped when finding the line that used it.
    LIB_DIR = "#{__dir__}/".freeze
    private_constant :LIB_DIR

    # The file that loads this library, whose lines are skipped too. Only the files of this library are skipped, rather
    # than every file of the directory that holds them, which can hold other libraries, such as `site_ruby`, or the
    # `lib` directory of an application that it is copied into.
    LIB_FILE = File.expand_path("../semantic_logger.rb", __dir__).freeze
    private_constant :LIB_FILE

    # The text that each warning starts with, after the location of the line that used what is deprecated.
    PREFIX = "SemanticLogger: ".freeze
    private_constant :PREFIX

    # A warning reported by .warn, as `Kernel#warn` passes it to `Warning.warn`, see .warning?.
    WARNING = /\A(?:.+:\d+: warning: )?#{Regexp.escape(PREFIX)}/
    private_constant :WARNING

    # The start of the paths of the code of Ruby itself, rather than of a file of it: the core methods that CRuby
    # writes in Ruby, such as `Kernel#tap`, and the standard library of JRuby, when it is loaded from its jar.
    RUBY_PATHS = ["<internal:", "uri:classloader:"].freeze
    private_constant :RUBY_PATHS

    # The directory of the standard library of Ruby.
    RUBY_LIB_DIRS = [RbConfig::CONFIG["rubylibdir"]].compact.map { |dir| "#{dir}/".freeze }.freeze
    private_constant :RUBY_LIB_DIRS

    # Reports that the application used something deprecated, unless deprecation warnings are off, with the message,
    # which says what is deprecated and what to use instead, after "SemanticLogger: ", at the line of the application
    # that used it, see .application_location, in the same form as `Kernel#warn` names the line of its caller, such as
    # `config/initializers/logging.rb:12: warning: SemanticLogger: old is deprecated, use new instead`, or without a
    # line when the call stack has none outside this library.
    #
    # Returns nil.
    def self.warn(message)
      return unless Warning[:deprecated]

      location = application_location
      text     = "#{PREFIX}#{message}"
      text     = "#{location.path}:#{location.lineno}: warning: #{text}" if location
      Kernel.warn(text, category: :deprecated)
      nil
    end

    # Returns [true|false] whether the message, as `Kernel#warn` passes it to `Warning.warn`, is a warning reported by
    # .warn, so that an application, or its tests, can tell the deprecation warnings of Semantic Logger from the others.
    def self.warning?(message)
      WARNING.match?(message)
    end

    # Returns [Thread::Backtrace::Location|nil] the line of the application that used this library, or nil when the
    # call stack has none outside this library. It is the first line of the call stack outside this library, other
    # than:
    # - A line of Ruby itself, see .ruby?, which runs on behalf of its caller, such as `Kernel#tap`, as Ruby names the
    #   caller of its own core methods.
    # - A line of a gem that this library called with a block, which has a line of this library further out in the
    #   call stack. A line of a gem that called this library, such as one of Rails Semantic Logger, is the one
    #   returned, since it is the gem that used it.
    #
    # The call stack is walked outward from the caller, until the line of the application is found, rather than
    # creating all of it.
    def self.application_location
      gem_dirs  = installed_gem_dirs
      candidate = nil
      Thread.each_caller_location do |location|
        if library?(location)
          candidate = nil
        elsif gem?(location, gem_dirs)
          candidate ||= location
        elsif !ruby?(location)
          return candidate || location
        end
      end
      candidate
    end
    private_class_method :application_location

    # Returns [true|false] whether the line of the call stack is in a file of this library. Code run with `eval` has
    # only the file name that it was given.
    def self.library?(location)
      file = location.absolute_path || location.path
      file.start_with?(LIB_DIR) || file == LIB_FILE
    end
    private_class_method :library?

    # Returns [true|false] whether the line of the call stack is in the code of Ruby itself: a core method, see
    # RUBY_PATHS, including one of JRuby, written in Java, or a file of the standard library of Ruby.
    def self.ruby?(location)
      path = location.path
      path.start_with?(*RUBY_PATHS) || path.end_with?(".java") || in_dirs?(location, RUBY_LIB_DIRS)
    end
    private_class_method :ruby?

    # Returns [true|false] whether the line of the call stack is in a file of a gem, in one of the directories of the
    # installed gems.
    def self.gem?(location, gem_dirs)
      in_dirs?(location, gem_dirs)
    end
    private_class_method :gem?

    # Returns [true|false] whether the file of the line of the call stack is in one of the directories, by the path
    # that it was loaded from, or its absolute path, which differs when the path holds a link.
    def self.in_dirs?(location, dirs)
      location.path.start_with?(*dirs) || location.absolute_path&.start_with?(*dirs) || false
    end
    private_class_method :in_dirs?

    # Returns [Array<String>] the directories of the installed gems, which Bundler can change once it is loaded. None
    # in a Ractor other than the main one, see RactorSupport.other_ractor?, which cannot read the paths of RubyGems, so
    # that a line of a gem is taken there as the line of the application.
    def self.installed_gem_dirs
      return [] if !defined?(::Gem) || RactorSupport.other_ractor?

      ::Gem.path.map { |dir| dir.end_with?("/") ? dir : "#{dir}/" }
    end
    private_class_method :installed_gem_dirs
  end
end
