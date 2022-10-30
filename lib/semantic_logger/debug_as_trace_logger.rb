module SemanticLogger
  # Custom logger that maps all calls to debug to trace calls
  # This is useful for existing gems / libraries that log too much to debug
  # when most of the debug logging should be at the trace level
  class DebugAsTraceLogger < Logger
    alias debug trace
    alias debug? trace?
    alias measure_debug measure_trace
    alias benchmark_debug benchmark_trace
  end
end
