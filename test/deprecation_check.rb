# Collects the deprecation warnings that Semantic Logger reports, see `SemanticLogger::Deprecation`, while a test
# runs, rather than writing them to `$stderr`, so that a test asserts each one that it expects with #assert_deprecated,
# and any other one fails the test, see DeprecationCheck, so that Semantic Logger never uses its own deprecated
# methods and options, and every test of one says so. Minitest turns deprecation warnings on.
#
# Copied from the tests of IOStreams, which report deprecations the same way.
module DeprecationCollector
  @mutex    = Mutex.new
  @warnings = nil

  # Starts collecting the warnings of a test.
  def self.start
    @mutex.synchronize { @warnings = [] }
  end

  # Returns [Array<String>] the warnings collected since .start, and stops collecting them.
  def self.stop
    @mutex.synchronize { @warnings.tap { @warnings = nil } }
  end

  # Returns [Array<String>] the warnings reported while the block ran, which are not collected for the test.
  def self.collect
    outer = @mutex.synchronize { @warnings.tap { @warnings = [] } }
    yield
    @mutex.synchronize { @warnings }
  ensure
    @mutex.synchronize { @warnings = outer }
  end

  # Returns [true|false] whether the warning was collected: one reported by Semantic Logger while a test runs, which
  # `SemanticLogger::Deprecation` tells from the others.
  def self.add(message)
    return false unless SemanticLogger::Deprecation.warning?(message)

    @mutex.synchronize { @warnings ? @warnings.push(message) && true : false }
  end

  # Collects the warnings of Semantic Logger, see .add, and writes any other one.
  module Warn
    def warn(message, *, **)
      super unless DeprecationCollector.add(message)
    end
  end
end
Warning.extend(DeprecationCollector::Warn)

# Fails a test that caused a Semantic Logger deprecation warning that it did not assert with #assert_deprecated, or that
# its class, such as a describe block, does not allow, see ClassMethods#allow_deprecation.
module DeprecationCheck
  module ClassMethods
    # Allows each test of this class, such as a describe block, and of its subclasses, such as the describe blocks
    # within a describe block, to report the Semantic Logger deprecation warnings that match the patterns, for the tests
    # of something deprecated that use it throughout. A describe block within a `Minitest::Test` class is not one of its
    # subclasses, but one of `Minitest::Spec`, so call it in the describe block instead.
    def allow_deprecation(*patterns)
      @allowed_deprecations = patterns
    end

    # Returns [Array<Regexp>] the patterns of the deprecation warnings that the tests of this class can report.
    def allowed_deprecations
      inherited = superclass.respond_to?(:allowed_deprecations) ? superclass.allowed_deprecations : []
      inherited + (@allowed_deprecations || [])
    end
  end

  def before_setup
    DeprecationCollector.start
    super
  end

  def after_teardown
    super
    allowed  = self.class.allowed_deprecations
    warnings = DeprecationCollector.stop.reject { |warning| allowed.any? { |pattern| warning.match?(pattern) } }
    return if warnings.empty?

    flunk("Unexpected Semantic Logger deprecation warnings, assert them with assert_deprecated:\n#{warnings.join}")
  end

  # Asserts that the block reports a Semantic Logger deprecation warning that matches each pattern, and none that
  # matches none of them, with deprecation warnings turned on while it runs.
  #
  # Returns the result of the block.
  def assert_deprecated(*patterns, &)
    raise(ArgumentError, "Supply the pattern of each deprecation warning that the block reports") if patterns.empty?

    result, warnings = deprecations_of(&)

    patterns.each do |pattern|
      assert(warnings.any? { |warning| warning.match?(pattern) },
             "Expected a Semantic Logger deprecation warning matching #{pattern.inspect}, got:\n#{warnings.join}")
    end
    unexpected = warnings.reject { |warning| patterns.any? { |pattern| warning.match?(pattern) } }

    assert_empty(unexpected, "Unexpected Semantic Logger deprecation warnings")
    result
  end

  # Asserts that the block reports no Semantic Logger deprecation warning, even in a class that allows some, see
  # ClassMethods#allow_deprecation, with deprecation warnings turned on while it runs.
  #
  # Returns the result of the block.
  def refute_deprecated(&)
    result, warnings = deprecations_of(&)

    assert_empty(warnings, "Unexpected Semantic Logger deprecation warnings")
    result
  end

  # Returns [Array] the result of the block, and the Semantic Logger deprecation warnings that it reported, with
  # deprecation warnings turned on while it runs.
  def deprecations_of
    result  = nil
    enabled = Warning[:deprecated]
    Warning[:deprecated] = true
    warnings = DeprecationCollector.collect { result = yield }
    [result, warnings]
  ensure
    Warning[:deprecated] = enabled
  end
end
Minitest::Test.prepend(DeprecationCheck)
Minitest::Test.extend(DeprecationCheck::ClassMethods)
