# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintListingEvidenceAdapterTest < Minitest::Test
  SHA = "d" * 40
  RELEASE = "a" * 64

  def lint(finding: nil, suppression: nil)
    package = {
      "identity" => {"name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0", "release_sha256" => RELEASE},
      "validator_findings" => [], "requested_permissions" => {}, "scanned_files" => [],
      "commands" => [], "hosts" => [], "findings" => finding ? [finding] : [],
      "suppressions" => suppression ? [suppression] : [],
      "counts" => {"hard" => 0, "advisory" => 0, "downgraded" => 0}, "verdict" => "pass"
    }
    HoneycombSecurityLint::Evidence.finalize({
      "schema" => "honeycomb.security-lint/v1",
      "event" => {"action" => "labeled", "gate" => "applied", "label_sha" => SHA},
      "pull_request" => 42, "base_sha" => "c" * 40, "head_sha" => SHA,
      "run" => {"id" => 7, "attempt" => 1, "workflow" => "Security lint", "repository" => "hive-sh/honeycomb"},
      "artifact_digest" => nil, "state" => "pass", "packages" => [package],
      "totals" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
      "verdict" => "Security lint passed"
    })
  end

  def approval(digest:, suppressions: [], head_sha: SHA, release: RELEASE)
    {
      "name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0",
      "release_sha256" => release, "head_sha" => head_sha, "reviewer" => "maintainer",
      "decision" => "approved", "reviewed_at" => "2026-07-16T11:00:00Z",
      "evidence_digest" => digest, "review_url" => "https://example.test/reviews/42",
      "notes" => "reviewed", "approved_suppressions" => suppressions
    }
  end

  def test_adapts_current_lint_and_approval_to_task_1848_reader_shape
    evidence = lint
    record = HoneycombSecurityLint::ListingEvidenceAdapter.build(
      lint_evidence: evidence,
      approvals: [approval(digest: evidence.fetch("artifact_digest"))],
      checked_at: "2026-07-16T10:00:00Z", tier: "reviewed"
    ).fetch("records").first

    assert_equal "pass", record.dig("lint", "status")
    assert_equal "approved", record.dig("approval", "status")
    assert_equal RELEASE, record.dig("lint", "release_sha256")
    assert_equal SHA, record.dig("approval", "head_sha")
  end

  def test_missing_approval_becomes_pending_but_stale_or_orphaned_approval_fails_closed
    evidence = lint
    pending = HoneycombSecurityLint::ListingEvidenceAdapter.build(
      lint_evidence: evidence, approvals: [], checked_at: "2026-07-16T10:00:00Z", tier: "reviewed"
    )
    assert_equal({"status" => "pending"}, pending.dig("records", 0, "approval"))

    [
      approval(digest: evidence.fetch("artifact_digest"), head_sha: "e" * 40),
      approval(digest: evidence.fetch("artifact_digest"), release: "f" * 64),
      approval(digest: "0" * 64)
    ].each do |stale|
      assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
        HoneycombSecurityLint::ListingEvidenceAdapter.build(
          lint_evidence: evidence, approvals: [stale],
          checked_at: "2026-07-16T10:00:00Z", tier: "reviewed"
        )
      end
    end
  end

  def test_reconstructs_preliminary_digest_for_exact_approved_suppressions
    fingerprint = "f" * 64
    finding = {
      "rule_id" => "secret.fixture", "category" => "secret", "original_severity" => "hard",
      "disposition" => "hard", "path" => "packages/example/1.0.0/README.md", "line" => 1,
      "column" => 1, "fingerprint" => fingerprint, "redacted_evidence" => "[redacted]",
      "message" => "Fixture secret", "request" => {"reason" => "Inert fixture"}, "approval" => nil
    }
    suppression = {"fingerprint" => fingerprint, "reason" => "Inert fixture", "status" => "requested", "approval" => nil}
    preliminary = lint(finding: finding, suppression: suppression)
    approved = approval(digest: preliminary.fetch("artifact_digest"), suppressions: [fingerprint])
    final = HoneycombSecurityLint::Evidence.apply_approvals(preliminary, [approved])

    document = HoneycombSecurityLint::ListingEvidenceAdapter.build(
      lint_evidence: final, approvals: [approved],
      checked_at: "2026-07-16T10:00:00Z", tier: "reviewed"
    )

    assert_equal "pass", document.dig("records", 0, "lint", "status")
    orphaned = Marshal.load(Marshal.dump(approved))
    orphaned["approved_suppressions"] = ["e" * 64]
    assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
      HoneycombSecurityLint::ListingEvidenceAdapter.build(
        lint_evidence: final, approvals: [orphaned],
        checked_at: "2026-07-16T10:00:00Z", tier: "reviewed"
      )
    end
  end
end
