# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintContractsTest < Minitest::Test
  SHA = "d" * 40
  DIGEST = "a" * 64

  def evidence
    {
      "schema" => "honeycomb.security-lint/v1",
      "event" => {"action" => "labeled", "gate" => "applied", "label_sha" => SHA},
      "pull_request" => 42,
      "base_sha" => "c" * 40,
      "head_sha" => SHA,
      "run" => {"id" => 7, "attempt" => 1, "workflow" => "Security lint", "repository" => "hive-sh/honeycomb"},
      "artifact_digest" => nil,
      "state" => "pass",
      "packages" => [{
        "identity" => {"name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0", "release_sha256" => DIGEST},
        "validator_findings" => [], "requested_permissions" => {}, "scanned_files" => [],
        "commands" => [], "hosts" => [], "findings" => [], "suppressions" => [],
        "counts" => {"hard" => 0, "advisory" => 0, "downgraded" => 0}, "verdict" => "pass"
      }],
      "totals" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
      "verdict" => "Security lint passed"
    }
  end

  def approval
    {
      "schema" => "honeycomb.listing-approval/v1",
      "approvals" => [{
        "name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0",
        "release_sha256" => DIGEST, "head_sha" => SHA, "reviewer" => "maintainer",
        "decision" => "approved", "reviewed_at" => "2026-07-16T10:00:00Z",
        "evidence_digest" => "b" * 64, "review_url" => "https://example.test/review/42",
        "notes" => "reviewed", "approved_suppressions" => ["e" * 64]
      }]
    }
  end

  def test_round_trips_strict_canonical_contracts
    evidence_bytes = HoneycombSecurityLint::Contracts.canonical_json(evidence)
    approvals_bytes = HoneycombSecurityLint::Contracts.canonical_json(approval)

    assert_equal evidence, HoneycombSecurityLint::Contracts.parse_evidence(evidence_bytes)
    assert_equal approval, HoneycombSecurityLint::Contracts.parse_approvals(approvals_bytes)
    assert_equal evidence_bytes, HoneycombSecurityLint::Contracts.canonical_json(JSON.parse(evidence_bytes))
    assert_equal Hash, JSON.parse(File.read(File.join(ROOT, "schemas", "security-lint-evidence-v1.json"))).class
    assert_equal Hash, JSON.parse(File.read(File.join(ROOT, "schemas", "listing-approval-v1.json"))).class
  end

  def test_rejects_unknown_duplicate_and_mismatched_identity_fields
    invalid = Marshal.load(Marshal.dump(evidence))
    invalid["packages"][0]["identity"]["surprise"] = true
    error = assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
      HoneycombSecurityLint::Contracts.validate_evidence(invalid)
    end
    assert_includes error.message, "unknown"

    assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
      HoneycombSecurityLint::Contracts.parse_evidence('{"schema":"one","schema":"two"}')
    end

    duplicate = Marshal.load(Marshal.dump(approval))
    duplicate["approvals"] << duplicate["approvals"].first
    assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
      HoneycombSecurityLint::Contracts.validate_approvals(duplicate)
    end
  end

  def test_approval_requires_exact_suppression_fingerprints_and_audit_identity
    invalid = Marshal.load(Marshal.dump(approval))
    invalid["approvals"][0]["approved_suppressions"] = ["secret.*"]
    error = assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
      HoneycombSecurityLint::Contracts.validate_approvals(invalid)
    end
    assert_includes error.message, "exact SHA-256"
  end
end
