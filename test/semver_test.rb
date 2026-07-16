# frozen_string_literal: true

require_relative "test_helper"

class SemVerTest < Minitest::Test
  def test_compares_semver_2_precedence
    ordered = %w[
      1.0.0-alpha
      1.0.0-alpha.1
      1.0.0-alpha.beta
      1.0.0-beta
      1.0.0-beta.2
      1.0.0-beta.11
      1.0.0-rc.1
      1.0.0
    ]

    parsed = ordered.reverse.map { |version| HoneycombRegistry::SemVer.parse(version) }
    assert_equal ordered, parsed.sort.map(&:to_s)
  end

  def test_build_metadata_does_not_affect_precedence
    first = HoneycombRegistry::SemVer.parse("1.2.3+build.1")
    second = HoneycombRegistry::SemVer.parse("1.2.3+build.2")

    assert_equal 0, first <=> second
    refute_equal first.to_s, second.to_s
  end

  def test_rejects_malformed_versions
    %w[1 1.2 v1.2.3 01.2.3 1.02.3 1.2.03 1.2.3-01 1.2.3-].each do |value|
      assert_raises(HoneycombRegistry::SemVer::Invalid) do
        HoneycombRegistry::SemVer.parse(value)
      end
    end
  end

  def test_latest_rejects_equal_precedence_build_variants
    error = assert_raises(HoneycombRegistry::SemVer::AmbiguousPrecedence) do
      HoneycombRegistry::SemVer.latest(%w[1.0.0+one 1.0.0+two])
    end
    assert_includes error.message, "equal precedence"
  end
end
