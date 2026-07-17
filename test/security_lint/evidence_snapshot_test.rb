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


  def test_selects_latest_append_only_decision_per_reviewer
    in_tmpdir do |root|
      record = lint
      lint_path = File.join(root, "lint", SHA, "#{record.fetch("artifact_digest")}.json")
      directory = File.join(root, "approvals", "example", "1.0.0", SHA)
      FileUtils.mkdir_p(File.dirname(lint_path))
      FileUtils.mkdir_p(directory)
      File.write(lint_path, HoneycombSecurityLint::Contracts.canonical_json(record))
      first = approval(record)
      latest = approval(record)
      latest["approvals"][0].merge!(
        "decision" => "denied", "reviewed_at" => "2026-07-17T11:00:00Z",
        "review_url" => "https://example.test/reviews/maintainer-2"
      )
      File.write(File.join(directory, "maintainer-a.json"), HoneycombSecurityLint::Contracts.canonical_json(first))
      File.write(File.join(directory, "maintainer-b.json"), HoneycombSecurityLint::Contracts.canonical_json(latest))

      document = HoneycombSecurityLint::EvidenceSnapshot.export(
        root: root, lint_paths: [lint_path], checked_at: "2026-07-17T12:00:00Z", release_tier: "community"
      )

      assert_equal ["denied"], document.dig("records", 0, "approvals").map { |entry| entry["status"] }
    end
  end


  def test_latest_decision_selection_is_scoped_per_honeycomb
    in_tmpdir do |root|
      record = lint
      second_package = Marshal.load(Marshal.dump(record.fetch("packages").first))
      second_package["identity"] = {
        "name" => "another", "version" => "1.0.0", "path" => "packages/another/1.0.0",
        "release_sha256" => "b" * 64
      }
      record["packages"] << second_package
      record["packages"].sort_by! { |package| package.dig("identity", "name") }
      record = HoneycombSecurityLint::Evidence.finalize(record)
      lint_path = File.join(root, "lint", SHA, "#{record.fetch("artifact_digest")}.json")
      FileUtils.mkdir_p(File.dirname(lint_path))
      File.write(lint_path, HoneycombSecurityLint::Contracts.canonical_json(record))

      %w[another example].each do |name|
        document = approval(record)
        item = document.fetch("approvals").first
        item["name"] = name
        item["path"] = "packages/#{name}/1.0.0"
        item["release_sha256"] = name == "another" ? "b" * 64 : RELEASE
        path = File.join(root, "approvals", name, "1.0.0", SHA, "maintainer-a.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, HoneycombSecurityLint::Contracts.canonical_json(document))
      end

      document = HoneycombSecurityLint::EvidenceSnapshot.export(
        root: root, lint_paths: [lint_path], checked_at: "2026-07-17T12:00:00Z", release_tier: "community"
      )

      reviewers = document.fetch("records").map do |item|
        item.dig("approvals", 0, "reviewer")
      end
      assert_equal %w[maintainer maintainer], reviewers
    end
  end


  def test_rejects_same_timestamp_decision_ties_instead_of_guessing
    in_tmpdir do |root|
      record = lint
      lint_path = File.join(root, "lint", SHA, "#{record.fetch("artifact_digest")}.json")
      directory = File.join(root, "approvals", "example", "1.0.0", SHA)
      FileUtils.mkdir_p(File.dirname(lint_path))
      FileUtils.mkdir_p(directory)
      File.write(lint_path, HoneycombSecurityLint::Contracts.canonical_json(record))
      first = approval(record)
      second = approval(record)
      second["approvals"][0].merge!(
        "decision" => "denied", "review_url" => "https://example.test/reviews/maintainer-2"
      )
      File.write(File.join(directory, "maintainer-a.json"), HoneycombSecurityLint::Contracts.canonical_json(first))
      File.write(File.join(directory, "maintainer-b.json"), HoneycombSecurityLint::Contracts.canonical_json(second))

      error = assert_raises(HoneycombSecurityLint::EvidenceSnapshot::Invalid) do
        HoneycombSecurityLint::EvidenceSnapshot.export(
          root: root, lint_paths: [lint_path], checked_at: "2026-07-17T12:00:00Z", release_tier: "community"
        )
      end
      assert_includes error.message, "ambiguous audit timestamp"
    end
  end
end
