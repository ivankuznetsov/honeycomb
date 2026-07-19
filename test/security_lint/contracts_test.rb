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

  def test_accepts_ruby_executable_evidence_kind_and_public_schema_matches
    document = evidence
    document["packages"][0]["commands"] << {
      "path" => "packages/example/1.0.0/tools/provider.rb",
      "line" => 7,
      "column" => 3,
      "kind" => "ruby",
      "redacted" => "Net::HTTP.get(uri)"
    }

    assert_equal document, HoneycombSecurityLint::Contracts.validate_evidence(document)

    schema = JSON.parse(File.read(File.join(ROOT, "schemas", "security-lint-evidence-v1.json")))
    assert_includes schema.dig("$defs", "command", "properties", "kind", "enum"), "ruby"
  end

  def test_canonical_json_has_runtime_independent_empty_containers_and_escaping
    value = {
      "z" => [],
      "a" => {"empty" => {}, "text" => "line\nquote\"slash\\snowman ☃", "true" => true},
      "n" => nil
    }
    expected = <<~JSON
      {
        "a": {
          "empty": {},
          "text": "line\\nquote\\\"slash\\\\snowman ☃",
          "true": true
        },
        "n": null,
        "z": []
      }
    JSON

    assert_equal expected, HoneycombSecurityLint::Contracts.canonical_json(value)
    assert_equal "99b3b5488259e03501eb6b1c210d30b2182ffe6a227d672f854475cd1aa9272c",
                 Digest::SHA256.hexdigest(expected)
  end

  def test_canonical_json_rejects_values_without_a_portable_contract_encoding
    error = assert_raises(JSON::GeneratorError) do
      HoneycombSecurityLint::Contracts.canonical_json({"ratio" => 1.5})
    end
    assert_includes error.message, "unsupported Float"

    assert_raises(JSON::GeneratorError) do
      HoneycombSecurityLint::Contracts.canonical_json({:symbol => "value"})
    end
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

  def test_allows_distinct_maintainers_but_rejects_case_insensitive_reviewer_duplicates
    records = approval
    second = Marshal.load(Marshal.dump(records["approvals"].first))
    second["reviewer"] = "second-maintainer"
    records["approvals"] << second
    assert_equal records, HoneycombSecurityLint::Contracts.validate_approvals(records)

    records["approvals"][1]["reviewer"] = "MAINTAINER"
    assert_raises(HoneycombSecurityLint::Contracts::Invalid) do
      HoneycombSecurityLint::Contracts.validate_approvals(records)
    end
  end

  def test_public_schemas_share_runtime_identity_constraints
    security = JSON.parse(File.read(File.join(ROOT, "schemas", "security-lint-evidence-v1.json")))
    approval_schema = JSON.parse(File.read(File.join(ROOT, "schemas", "listing-approval-v1.json")))
    listing = JSON.parse(File.read(File.join(ROOT, "schemas", "listing-evidence-v1.json")))
    catalog = JSON.parse(File.read(File.join(ROOT, "schemas", "catalog-v2.json")))

    [security, approval_schema, listing, catalog].each do |schema|
      pattern = Regexp.new(schema.dig("$defs", "semver", "pattern"))
      assert_match pattern, "1.2.3-rc.1+build.5"
      refute_match pattern, "01.2.3"
      refute_match pattern, "not-semver"
    end
    assert_equal({"$ref" => "#/$defs/semver"}, security.dig("$defs", "package", "properties", "identity", "properties", "version"))
    assert_equal({"$ref" => "#/$defs/sha"}, security.dig("properties", "event", "properties", "label_sha", "oneOf", 0))
    workflow = Regexp.new(listing.dig("$defs", "verification", "properties", "attestation", "properties", "workflow", "pattern"))
    assert_match workflow, "hive-sh/honeycomb/.github/workflows/release.yml@refs/heads/main"
    refute_match workflow, "arbitrary-workflow"
  end
end
