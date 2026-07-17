# frozen_string_literal: true

require_relative "../test_helper"
require_relative "evidence_test"
require "honeycomb_security_lint"

class SecurityLintRendererTest < Minitest::Test
  def test_comment_and_summary_share_sections_counts_and_verdict
    evidence = HoneycombSecurityLint::Evidence.finalize(SecurityLintEvidenceTest.new("test").document)
    renderer = HoneycombSecurityLint::Renderer.new(max_items: 20)

    comment = renderer.comment(evidence)
    summary = renderer.summary(evidence)

    assert comment.start_with?(HoneycombSecurityLint::Renderer::COMMENT_MARKER)
    %w[Validator Permissions Commands Network Deny-pattern Secret/PII Suppressions Verdict].each do |heading|
      assert_includes comment, heading
      assert_includes summary, heading
    end
    assert_includes comment, "Hard: 1"
    assert_includes summary, "Hard: 1"
    assert_includes comment, "Honeycomb `example` `1.0.0`"
  end

  def test_attacker_controlled_markdown_mentions_workflow_commands_and_secrets_stay_inert
    record = SecurityLintEvidenceTest.new("test").document
    secret = "ghp_" + "A" * 24
    finding = record.dig("packages", 0, "findings", 0)
    finding["message"] = "# [click](javascript:bad) @everyone ::error:: #{secret}"
    finding["redacted_evidence"] = HoneycombSecurityLint::SecretPiiScanner.new.redact_text(secret)
    rendered = HoneycombSecurityLint::Renderer.new(max_items: 20).comment(
      HoneycombSecurityLint::Evidence.finalize(record)
    )

    refute_includes rendered, secret
    refute_includes rendered, "javascript:bad"
    refute_includes rendered, "@everyone"
    refute_match(/^::error::/, rendered)
  end

  def test_caps_each_section_with_an_explicit_truncation_count
    record = SecurityLintEvidenceTest.new("test").document
    record.dig("packages", 0, "commands").concat(
      3.times.map { |index| {"path" => "packages/example/1.0.0/README.md", "line" => index + 1, "column" => 1, "kind" => "fenced", "redacted" => "echo #{index}"} }
    )
    rendered = HoneycombSecurityLint::Renderer.new(max_items: 1).summary(
      HoneycombSecurityLint::Evidence.finalize(record)
    )

    assert_includes rendered, "2 more items omitted"
  end
end
