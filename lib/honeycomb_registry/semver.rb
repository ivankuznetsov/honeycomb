# frozen_string_literal: true

module HoneycombRegistry
  class SemVer
    include Comparable

    class Invalid < ArgumentError; end
    class AmbiguousPrecedence < ArgumentError; end

    PATTERN = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z/

    attr_reader :major, :minor, :patch, :prerelease, :build

    def self.parse(value)
      raise Invalid, "version must be a string" unless value.is_a?(String)

      match = PATTERN.match(value)
      raise Invalid, "invalid SemVer 2.0 version: #{value.inspect}" unless match

      new(value, match)
    end

    def self.latest(values)
      parsed = values.map { |value| value.is_a?(self) ? value : parse(value) }
      parsed.combination(2) do |left, right|
        if (left <=> right).zero? && left.to_s != right.to_s
          raise AmbiguousPrecedence,
                "versions #{left} and #{right} have equal precedence; latest is ambiguous"
        end
      end
      parsed.max
    end

    def initialize(text, match)
      @text = text.freeze
      @major = Integer(match[1], 10)
      @minor = Integer(match[2], 10)
      @patch = Integer(match[3], 10)
      @prerelease = match[4]&.split(".")&.freeze
      @build = match[5]&.split(".")&.freeze
      freeze
    end

    def <=>(other)
      return nil unless other.is_a?(SemVer)

      core = [major, minor, patch] <=> [other.major, other.minor, other.patch]
      return core unless core.zero?
      return 0 if prerelease.nil? && other.prerelease.nil?
      return 1 if prerelease.nil?
      return -1 if other.prerelease.nil?

      compare_prerelease(prerelease, other.prerelease)
    end

    def to_s
      @text
    end

    private

    def compare_prerelease(left, right)
      [left.length, right.length].max.times do |index|
        return -1 unless left[index]
        return 1 unless right[index]

        comparison = compare_identifier(left[index], right[index])
        return comparison unless comparison.zero?
      end
      0
    end

    def compare_identifier(left, right)
      left_numeric = left.match?(/\A\d+\z/)
      right_numeric = right.match?(/\A\d+\z/)
      return Integer(left, 10) <=> Integer(right, 10) if left_numeric && right_numeric
      return -1 if left_numeric
      return 1 if right_numeric

      left <=> right
    end
  end
end
