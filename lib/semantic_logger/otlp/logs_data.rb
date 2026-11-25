module SemanticLogger
  module Otlp
    # The envelope of OTLP log records, the Hash of an ExportLogsServiceRequest in its JSON encoding,
    # which is also that of a LogsData, as an OTLP file holds it: one ResourceLogs with the resource of
    # the process, and one ScopeLogs for each logger name, its instrumentation scope named after it, such
    # as "MyApp::Orders".
    #
    # It knows how the records are wrapped, not how each is mapped (see Formatters::Otlp), nor where the
    # request goes: Appender::Otlp posts it, and Formatters::OtlpJsonLines writes it as one line.
    module LogsData
      # Returns [Hash] the request of the records, by the name of their logger, with the attributes of the
      # resource (see Resource#process_attributes).
      def self.request(resource_attributes, scopes)
        {
          resourceLogs: [
            {
              resource:  {attributes: Values.attributes(resource_attributes)},
              scopeLogs: scopes.map do |name, records|
                {scope: {name: Values.text(name)}, logRecords: records}
              end
            }
          ]
        }
      end
    end
  end
end
