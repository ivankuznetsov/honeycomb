# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintListingApprovalCliTest < Minitest::Test
  SCRIPT = File.join(ROOT, "script", "honeycomb-listing-approval")
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

  def test_offline_export_writes_task_1848_normalized_evidence
    in_tmpdir do |root|
      record = lint
      relative_lint = File.join("lint", SHA, "#{record.fetch("artifact_digest")}.json")
      lint_path = File.join(root, relative_lint)
      approval_path = File.join(root, "approvals", "example", "1.0.0", SHA, "maintainer.json")
      output = File.join(root, "listing-evidence.json")
      FileUtils.mkdir_p(File.dirname(lint_path))
      FileUtils.mkdir_p(File.dirname(approval_path))
      File.write(lint_path, HoneycombSecurityLint::Contracts.canonical_json(record))
      approval = {
        "schema" => HoneycombSecurityLint::Contracts::APPROVAL_SCHEMA,
        "approvals" => [{
          "name" => "example", "version" => "1.0.0", "path" => "packages/example/1.0.0",
          "release_sha256" => RELEASE, "head_sha" => SHA, "reviewer" => "maintainer",
          "decision" => "approved", "reviewed_at" => "2026-07-17T10:00:00Z",
          "evidence_digest" => record.fetch("artifact_digest"),
          "review_url" => "https://example.test/reviews/maintainer", "notes" => "reviewed",
          "approved_suppressions" => []
        }]
      }
      File.write(approval_path, HoneycombSecurityLint::Contracts.canonical_json(approval))

      stdout, stderr, status = capture_command(
        SCRIPT, "export", "--snapshot", root, "--lint", relative_lint,
        "--checked-at", "2026-07-17T09:00:00Z", "--release-tier", "community",
        "--output", output
      )

      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
      loaded = HoneycombRegistry::ListingEvidence.load(output)
      refute loaded.findings.errors?, loaded.findings.to_h.inspect
      assert HoneycombRegistry::ListingEvidence.eligible?(loaded.records.first)
    end
  end
end
