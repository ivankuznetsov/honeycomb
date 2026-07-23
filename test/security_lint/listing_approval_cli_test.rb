# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"
require "stringio"

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
      previous = File.join(root, "previous-listing-evidence.json")
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
      File.write(previous, HoneycombSecurityLint::Contracts.canonical_json({
        "schema" => HoneycombRegistry::ListingEvidence::SCHEMA, "records" => []
      }))

      stdout, stderr, status = capture_command(
        SCRIPT, "export", "--snapshot", root, "--lint", relative_lint,
        "--previous", previous,
        "--checked-at", "2026-07-17T09:00:00Z", "--release-tier", "community",
        "--output", output
      )

      assert_equal 0, status.exitstatus, [stdout, stderr].join("\n")
      loaded = HoneycombRegistry::ListingEvidence.load(output)
      refute loaded.findings.errors?, loaded.findings.to_h.inspect
      assert HoneycombRegistry::ListingEvidence.eligible?(loaded.records.first)
    end
  end

  def test_issue_passes_the_pinned_default_branch_sha_to_the_issuer
    load SCRIPT

    in_tmpdir do |root|
      event_path = File.join(root, "event.json")
      File.write(event_path, JSON.generate({
        "repository" => {"full_name" => "hive-sh/honeycomb", "default_branch" => "main"}
      }))
      captured = nil
      fake_issuer = Object.new
      fake_issuer.define_singleton_method(:issue) { {"name" => "example"} }
      environment = {
        "GITHUB_REPOSITORY" => "hive-sh/honeycomb",
        "GITHUB_TOKEN" => "token",
        "GITHUB_RUN_ID" => "88",
        "DEFAULT_BRANCH_SHA" => "f" * 40
      }

      status = HoneycombSecurityLint::ListingApprovalCLI.run(
        ["issue", "--event", event_path, "--root", root],
        out: StringIO.new,
        err: StringIO.new,
        env: environment,
        default_root: ROOT,
        client_factory: ->(**) { Object.new },
        store_factory: ->(**) { Object.new },
        issuer_factory: lambda do |**arguments|
          captured = arguments
          fake_issuer
        end
      )

      assert_equal 0, status
      assert_equal "f" * 40, captured.fetch(:default_branch_sha)
      assert_equal File.expand_path(root), captured.fetch(:root)
    end
  end
end
