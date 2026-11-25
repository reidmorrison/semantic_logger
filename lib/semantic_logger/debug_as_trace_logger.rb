module SemanticLogger
  # Custom logger that maps all calls to debug to trace calls
  # This is useful for existing gems / libraries that log too much to debug
  # when most of the debug logging should be at the trace level
  class DebugAsTraceLogger < Logger
    alias debug trace
    alias debug? trace?
    alias measure_debug measure_trace

    # Deprecated: use measure_debug, which takes the same arguments. Removed in v6.
    def benchmark_debug(message, params = {}, &)
      SemanticLogger::Deprecation.warn(
        "benchmark_debug is deprecated and removed in v6. Use measure_debug, which takes the same arguments."
      )
      measure_trace(message, params, &)
    end
  end
end
