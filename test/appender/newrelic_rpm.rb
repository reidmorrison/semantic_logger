# Mocked NewRelic::Agent used for testing

module NewRelic
  module Agent
    def self.notice_error(message, hash)
    end

    def self.record_metric(name, secoonds)
    end

    def self.increment_metric(name, count=1)
    end
  end
end
