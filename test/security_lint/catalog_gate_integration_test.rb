# frozen_string_literal: true

require_relative "../test_helper"
require "honeycomb_security_lint"

class SecurityLintCatalogGateIntegrationTest < Minitest::Test
  CATALOG = File.join(ROOT, "script", "honeycomb-catalog")
  SHA = "d" * 40

  def canonical_honeycomb(root)
    package_path = install_valid_fixture(root)
    package = HoneycombRegistry::Package.new(package_path, root: root)
    result = HoneycombRegistry::Manifest.generate(package)
    raise result.findings.to_h.inspect if result.findings.errors?
    package
  end

  def lint_evidence(package, state: "pass", head_sha: SHA)
    manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
    package_result = {
      "identity" => {
        "name" => package.name, "version" => package.version, "path" => package.relative_path,
        "release_sha256" => manifest.fetch("release_sha256")
      },
      "validator_findings" => [], "requested_permissions" => manifest.fetch("permissions"),
      "scanned_files" => [], "commands" => [], "hosts" => [], "findings" => [], "suppressions" => [],
      "counts" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
      "verdict" => state == "pass" ? "pass" : "fail"
    }
    if state == "fail"
      package_result["validator_findings"] << {
        "path" => package.relative_manifest_path, "code" => "fixture.blocked",
        "message" => "Blocked fixture", "severity" => "error"
      }
    end
    HoneycombSecurityLint::Evidence.finalize({
      "schema" => "honeycomb.security-lint/v1",
      "event" => {"action" => "labeled", "gate" => "applied", "label_sha" => head_sha},
      "pull_request" => 42, "base_sha" => "c" * 40, "head_sha" => head_sha,
      "run" => {"id" => 7, "attempt" => 1, "workflow" => "Security lint", "repository" => "hive-sh/honeycomb"},
      "artifact_digest" => nil, "state" => state, "packages" => [package_result],
      "totals" => {"hard" => 0, "advisory" => 0, "downgraded" => 0},
      "verdict" => state == "pass" ? "Security lint passed" : "Security lint found blocking evidence"
    })
  end

  def approval(evidence)
    identity = evidence.dig("packages", 0, "identity")
    {
      "name" => identity.fetch("name"), "version" => identity.fetch("version"),
      "path" => identity.fetch("path"), "release_sha256" => identity.fetch("release_sha256"),
      "head_sha" => evidence.fetch("head_sha"), "reviewer" => "registry-reviewer",
      "decision" => "approved", "reviewed_at" => "2026-07-16T11:00:00Z",
      "evidence_digest" => evidence.fetch("artifact_digest"),
      "review_url" => "https://example.test/reviews/example-1.0.0", "notes" => "reviewed",
      "approved_suppressions" => []
    }
  end

  def write_listing_evidence(root, lint, approvals)
    document = HoneycombSecurityLint::ListingEvidenceAdapter.build(
      lint_evidence: lint, approvals: approvals,
      checked_at: "2026-07-16T10:00:00Z", release_tier: "community"
    )
    path = File.join(root, "listing-evidence.json")
    File.write(path, HoneycombSecurityLint::Contracts.canonical_json(document))
    path
  end

  def run_catalog(root, evidence_path)
    capture_command(CATALOG, "--root", root, "--evidence", evidence_path)
  end

  def test_actual_catalog_command_lists_only_current_lint_plus_human_approval
    in_tmpdir do |root|
      package = canonical_honeycomb(root)
      lint = lint_evidence(package)

      review_path = File.join(root, "reviews", package.name, package.version, "community-reviewer.md")
      FileUtils.mkdir_p(File.dirname(review_path))
      File.write(review_path, "---\nreviewer: community-reviewer\nverdict: approve\n---\n")

      evidence_path = write_listing_evidence(root, lint, [])
      _stdout, stderr, status = run_catalog(root, evidence_path)
      assert_equal 0, status.exitstatus, stderr
      assert_empty JSON.parse(File.read(File.join(root, "catalog.json"))).fetch("entries")

      evidence_path = write_listing_evidence(root, lint, [approval(lint)])
      _stdout, stderr, status = run_catalog(root, evidence_path)
      assert_equal 0, status.exitstatus, stderr
      entries = JSON.parse(File.read(File.join(root, "catalog.json"))).fetch("entries")
      assert_equal ["example"], entries.map { |entry| entry.fetch("name") }
      assert_equal SHA, entries.first.dig("listing_approval", "head_sha")
      assert_equal "https://github.com/ivankuznetsov/honeycomb/tree/main/reviews/example/1.0.0",
                   entries.first.fetch("reviews_url")

      failed = lint_evidence(package, state: "fail")
      evidence_path = write_listing_evidence(root, failed, [approval(failed)])
      _stdout, stderr, status = run_catalog(root, evidence_path)
      assert_equal 0, status.exitstatus, stderr
      assert_empty JSON.parse(File.read(File.join(root, "catalog.json"))).fetch("entries")
    end
  end

  def test_stale_identity_and_changed_bytes_never_list
    in_tmpdir do |root|
      package = canonical_honeycomb(root)
      lint = lint_evidence(package)
      stale = approval(lint).merge("head_sha" => "e" * 40)
      assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
        write_listing_evidence(root, lint, [stale])
      end

      evidence_path = write_listing_evidence(root, lint, [approval(lint)])
      File.write(File.join(package.path, "README.md"), "changed after review\n")
      _stdout, _stderr, status = run_catalog(root, evidence_path)
      assert_equal 1, status.exitstatus
      refute File.exist?(File.join(root, "catalog.json"))
    end
  end
end
