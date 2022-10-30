module SemanticLogger
  # Custom logger that maps all calls to debug to trace calls
  # This is useful for existing gems / libraries that log too much to debug
  # when most of the debug logging should be at the trace level
  class DebugAsTraceLogger < Logger
    alias_method :debug, :trace
    alias_method :debug?, :trace?
    alias_method :measure_debug, :measure_trace
    alias_method :benchmark_debug, :benchmark_trace
  end
end
