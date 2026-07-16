# frozen_string_literal: true

module HoneycombRegistry
  Finding = Struct.new(:path, :code, :message, :severity, keyword_init: true) do
    def to_h
      {
        "path" => path,
        "code" => code,
        "message" => message,
        "severity" => severity
      }
    end
  end

  class Findings
    include Enumerable

    SEVERITY_ORDER = {"error" => 0, "warning" => 1, "info" => 2}.freeze
    VALID_SEVERITIES = SEVERITY_ORDER.keys.freeze

    def initialize(values = [])
      @values = []
      concat(values)
    end

    def add(path, code, message, severity = :error)
      severity = severity.to_s
      raise ArgumentError, "unknown finding severity: #{severity}" unless VALID_SEVERITIES.include?(severity)

      @values << Finding.new(path: path.to_s, code: code.to_s,
                             message: message.to_s, severity: severity)
      self
    end

    def concat(values)
      values.each do |value|
        if value.is_a?(Finding)
          @values << value
        elsif value.is_a?(Findings)
          @values.concat(value.to_a)
        else
          raise ArgumentError, "expected a Finding or Findings"
        end
      end
      self
    end

    def each(&block)
      sorted.each(&block)
    end

    def sorted
      @values.sort_by do |finding|
        [finding.path, SEVERITY_ORDER.fetch(finding.severity), finding.code, finding.message]
      end
    end

    def errors?
      @values.any? { |finding| finding.severity == "error" }
    end

    def codes
      sorted.map(&:code)
    end

    def empty?
      @values.empty?
    end

    def length
      @values.length
    end

    def to_a
      @values.dup
    end

    def to_h
      sorted.map(&:to_h)
    end
  end
end
