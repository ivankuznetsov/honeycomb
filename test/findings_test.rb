# frozen_string_literal: true

require_relative "test_helper"

class FindingsTest < Minitest::Test
  def test_sorts_and_serializes_with_exact_public_keys
    findings = HoneycombRegistry::Findings.new
    findings.add("z", "later", "later", :warning)
    findings.add("a", "info", "info", :info)
    findings.add("a", "error", "error", :error)

    assert_equal ["error", "info", "later"], findings.sorted.map(&:code)
    assert_equal %w[path code message severity], findings.sorted.first.to_h.keys
  end

  def test_only_errors_make_the_collection_fail
    findings = HoneycombRegistry::Findings.new
    findings.add("manifest.yml", "notice", "notice", :info)
    findings.add("manifest.yml", "caution", "caution", :warning)
    refute findings.errors?

    findings.add("manifest.yml", "broken", "broken", :error)
    assert findings.errors?
  end
end
