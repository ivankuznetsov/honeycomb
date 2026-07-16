# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintEvidenceTest < Minitest::Test
  SHA = "d" * 40
  RELEASE = "a" * 64

  def finding
    {
      "rule_id" => "secret.fixture", "category" => "secret",
      "original_severity" => "hard", "disposition" => "hard",
      "path" => "packages/example/1.0.0/README.md", "line" => 2, "column" => 3,
      "fingerprint" => "f" * 64, "redacted_evidence" => "[redacted]",
      "message" => "Fixture credential detected", "request" => nil, "approval" => nil
    }
  end

  def document(finding_record: finding)
    {
      "schema" => "honeycomb.security-lint/v1",
      "event" => {"action" => "labeled", "gate" => "applied", "label_sha" => SHA},
      "pull_request" => 42, "base_sha" => "c" * 40, "head_sha" => SHA,
      "run" => {"id" => 7, "attempt" => 1, "workflow" => "Security lint", "repository" => "hive-sh/honeycomb"},
      "artifact_digest" => nil, "state" => "fail",
      "packages" => [{
        "identity" => {"name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0", "release_sha256" => RELEASE},
        "validator_findings" => [], "requested_permissions" => {}, "scanned_files" => [],
        "commands" => [], "hosts" => [], "findings" => [finding_record], "suppressions" => [],
        "counts" => {"hard" => 1, "advisory" => 0, "downgraded" => 0}, "verdict" => "fail"
      }],
      "totals" => {"hard" => 1, "advisory" => 0, "downgraded" => 0},
      "verdict" => "Security lint found blocking evidence"
    }
  end

  def test_finalizes_counts_state_and_a_self_verifying_digest
    evidence = HoneycombSecurityLint::Evidence.finalize(document)

    assert_equal "fail", evidence.fetch("state")
    assert_equal({"hard" => 1, "advisory" => 0, "downgraded" => 0}, evidence.fetch("totals"))
    assert HoneycombSecurityLint::Contracts.artifact_digest_valid?(evidence)
    assert_equal evidence, HoneycombSecurityLint::Contracts.validate_evidence(evidence)
  end

  def test_exact_current_approval_downgrades_without_hiding_the_finding
    requested = document
    requested_finding = requested.dig("packages", 0, "findings", 0)
    requested_finding["request"] = {"reason" => "Known inert fixture"}
    requested.dig("packages", 0, "suppressions") << {
      "fingerprint" => requested_finding.fetch("fingerprint"), "reason" => "Known inert fixture", "status" => "requested", "approval" => nil
    }
    preliminary = HoneycombSecurityLint::Evidence.finalize(requested)
    approval = {
      "name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0",
      "release_sha256" => RELEASE, "head_sha" => SHA, "reviewer" => "maintainer",
      "decision" => "approved", "reviewed_at" => "2026-07-16T10:00:00Z",
      "evidence_digest" => preliminary.fetch("artifact_digest"),
      "review_url" => "https://example.test/review/42", "notes" => "reviewed",
      "approved_suppressions" => [requested_finding.fetch("fingerprint")]
    }

    final = HoneycombSecurityLint::Evidence.apply_approvals(preliminary, [approval])
    resolved = final.dig("packages", 0, "findings", 0)

    assert_equal "downgraded", resolved.fetch("disposition")
    assert_equal "hard", resolved.fetch("original_severity")
    assert_equal "maintainer", resolved.dig("approval", "reviewer")
    assert_equal "pass", final.fetch("state")
    assert_equal 1, final.dig("totals", "downgraded")
  end

  def test_stale_or_unrequested_approval_cannot_downgrade
    preliminary = HoneycombSecurityLint::Evidence.finalize(document)
    approval = {
      "name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0",
      "release_sha256" => RELEASE, "head_sha" => "e" * 40, "reviewer" => "maintainer",
      "decision" => "approved", "reviewed_at" => "2026-07-16T10:00:00Z",
      "evidence_digest" => preliminary.fetch("artifact_digest"),
      "review_url" => "https://example.test/review/42", "notes" => "reviewed",
      "approved_suppressions" => [finding.fetch("fingerprint")]
    }

    final = HoneycombSecurityLint::Evidence.apply_approvals(preliminary, [approval])

    assert_equal "hard", final.dig("packages", 0, "findings", 0, "disposition")
    assert_equal "fail", final.fetch("state")
  end
end
