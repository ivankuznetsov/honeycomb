# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintEvidenceSnapshotTest < Minitest::Test
  SHA = "d" * 40
  RELEASE = "a" * 64

  def lint
    HoneycombSecurityLint::Evidence.finalize({
      "schema" => "honeycomb.security-lint/v1",
      "event" => {"action" => "labeled", "gate" => "applied", "label_sha" => SHA},
      "pull_request" => 42, "base_sha" => "c" * 40, "head_sha" => SHA,
      "run" => {"id" => 7, "attempt" => 1, "workflow" => "Security lint", "repository" => "hive-sh/honeycomb"},
      "artifact_digest" => nil, "state" => "pass",
      "packages" => [{
        "identity" => {"name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0", "release_sha256" => RELEASE},
        "validator_findings" => [], "requested_permissions" => {"risk" => "low"},
        "scanned_files" => [], "commands" => [], "hosts" => [], "findings" => [],
        "suppressions" => [], "counts" => {"hard" => 0, "advisory" => 0, "downgraded" => 0}, "verdict" => "pass"
      }],
      "totals" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
      "verdict" => "Security lint passed"
    })
  end

  def approval(record, reviewer: "maintainer")
    {
      "schema" => HoneycombSecurityLint::Contracts::APPROVAL_SCHEMA,
      "approvals" => [{
        "name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0",
        "release_sha256" => RELEASE, "head_sha" => SHA, "reviewer" => reviewer,
        "decision" => "approved", "reviewed_at" => "2026-07-17T10:00:00Z",
        "evidence_digest" => record.fetch("artifact_digest"),
        "review_url" => "https://example.test/reviews/#{reviewer}", "notes" => "reviewed",
        "approved_suppressions" => []
      }]
    }
  end

  def test_exports_selected_lint_and_matching_append_only_approvals_deterministically
    in_tmpdir do |root|
      record = lint
      lint_path = File.join(root, "lint", SHA, "#{record.fetch("artifact_digest")}.json")
      approval_path = File.join(root, "approvals", "example", "1.0.0", SHA, "maintainer.json")
      FileUtils.mkdir_p(File.dirname(lint_path))
      FileUtils.mkdir_p(File.dirname(approval_path))
      File.write(lint_path, HoneycombSecurityLint::Contracts.canonical_json(record))
      File.write(approval_path, HoneycombSecurityLint::Contracts.canonical_json(approval(record)))

      document = HoneycombSecurityLint::EvidenceSnapshot.export(
        root: root, lint_paths: [lint_path], checked_at: "2026-07-17T09:00:00Z",
        release_tier: "community"
      )

      assert_equal HoneycombRegistry::ListingEvidence::SCHEMA, document.fetch("schema")
      assert_equal "approved", document.dig("records", 0, "approvals", 0, "status")
      assert_equal "maintainer", document.dig("records", 0, "approvals", 0, "reviewer")
      assert_equal document, JSON.parse(HoneycombSecurityLint::Contracts.canonical_json(document))
    end
  end

  def test_rejects_lint_outside_snapshot_and_symlinked_approval
    in_tmpdir do |root|
      outside = File.join(File.dirname(root), "outside-evidence.json")
      File.write(outside, HoneycombSecurityLint::Contracts.canonical_json(lint))
      assert_raises(HoneycombSecurityLint::EvidenceSnapshot::Invalid) do
        HoneycombSecurityLint::EvidenceSnapshot.export(
          root: root, lint_paths: [outside], checked_at: "2026-07-17T09:00:00Z", release_tier: "community"
        )
      end


      record = lint
      lint_path = File.join(root, "lint", SHA, "#{record.fetch("artifact_digest")}.json")
      directory = File.join(root, "approvals", "example", "1.0.0")
      FileUtils.mkdir_p(File.dirname(lint_path))
      FileUtils.mkdir_p(directory)
      File.write(lint_path, HoneycombSecurityLint::Contracts.canonical_json(record))
      File.symlink(File.dirname(outside), File.join(directory, SHA))
      assert_raises(HoneycombSecurityLint::EvidenceSnapshot::Invalid) do
        HoneycombSecurityLint::EvidenceSnapshot.export(
          root: root, lint_paths: [lint_path], checked_at: "2026-07-17T09:00:00Z", release_tier: "community"
        )
      end
    ensure
      File.unlink(outside) if outside && File.exist?(outside)
    end
  end
end
