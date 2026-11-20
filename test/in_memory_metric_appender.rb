# A metric appender that keeps in memory the snapshots of metrics that it writes.
class InMemoryMetricAppender < SemanticLogger::Subscriber
  include SemanticLogger::Metric::Snapshots

  attr_reader :snapshots

  def initialize(**args)
    @snapshots = []
    super
  end

  def write_metrics(snapshot)
    @snapshots << snapshot
  end

  # Returns [Array<SemanticLogger::Metric::Snapshot::Point>] the points of every snapshot written.
  def points
    @snapshots.flat_map(&:points)
  end
end
