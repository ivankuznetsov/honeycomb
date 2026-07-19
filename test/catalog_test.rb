# frozen_string_literal: true

require_relative "test_helper"

class CatalogTest < Minitest::Test
  def canonical_package(root, version: "1.0.0")
    package_path = if version == "1.0.0"
                     install_valid_fixture(root)
                   else
                     source = fixture_path("packages", "valid", "example", "1.0.0")
                     target = File.join(root, "packages", "example", version)
                     FileUtils.mkdir_p(File.dirname(target))
                     FileUtils.cp_r(source, target)
                     manifest = File.join(target, "manifest.yml")
                     File.write(manifest, File.read(manifest).sub("version: 1.0.0", "version: #{version}"))
                     target
                   end
    package = HoneycombRegistry::Package.new(package_path, root: root)
    result = HoneycombRegistry::Manifest.generate(package)
    raise result.findings.to_h.inspect if result.findings.errors?
    package
  end

  def evidence_record(package, lint: "pass", approval: "approved", head: "d" * 40,
                      release_tier: "community", current_tier: release_tier,
                      state: "listed", approval_count: 1, approval_authority: nil, verification: nil,
                      history: [], advisories: [])
    manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
    release = manifest.fetch("release_sha256")
    approvals = if approval == "pending"
                  []
                else
                  Array.new(approval_count) do |index|
                    approval_record = {
                      "status" => approval,
                      "release_sha256" => release,
                      "head_sha" => head,
                      "reviewer" => "registry-reviewer-#{index + 1}",
                      "reviewed_at" => "2026-07-16T11:0#{index}:00Z",
                      "review_url" => "https://example.test/reviews/#{package.name}-#{package.version}-#{index + 1}",
                      "evidence_digest" => ("#{index + 1}" * 64)[0, 64]
                    }
                    approval_record["authority"] = approval_authority if approval_authority
                    approval_record
                  end
                end
    {
      "name" => package.name,
      "version" => package.version,
      "release_tier" => release_tier,
      "current_tier" => current_tier,
      "permission_risk" => manifest.dig("permissions", "risk"),
      "state" => state,
      "lint" => lint == "pending" ? {"status" => "pending"} : {
        "status" => lint,
        "release_sha256" => release,
        "head_sha" => head,
        "checked_at" => "2026-07-16T10:00:00Z"
      },
      "approvals" => approvals,
      "verification" => verification,
      "history" => history,
      "advisories" => advisories
    }
  end

  def write_evidence(root, records)
    path = File.join(root, "evidence.json")
    File.write(path, JSON.pretty_generate({
      "schema" => "honeycomb-listing-evidence/v1", "records" => records
    }) + "\n")
    path
  end

  def write_community_review(root, package, record, reviewer: "community-reviewer")
    manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
    path = File.join(root, "reviews", package.name, package.version, "#{reviewer}.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~MARKDOWN)
      ---
      reviewer: "#{reviewer}"
      name: "#{package.name}"
      version: "#{package.version}"
      source_sha: "#{manifest.dig("source", "revision")}"
      release_sha256: "#{manifest.fetch("release_sha256")}"
      head_sha: "#{record.dig("lint", "head_sha")}"
      reviewed_at: "2026-07-17"
      verdict: "approve"
      conflict_of_interest: "none"
      ---
      # Community review

      ## Scope reviewed

      I reviewed every packaged file.

      ## Permission observations

      Declared permissions match the observed behavior.

      ## Findings

      None observed.

      ## Rationale

      The package and its declarations agree.
    MARKDOWN
    path
  end

  def test_missing_pending_and_denied_evidence_omit_without_failure
    in_tmpdir do |root|
      package = canonical_package(root)
      cases = [[], [evidence_record(package, lint: "pending")],
               [evidence_record(package, approval: "pending")],
               [evidence_record(package, approval: "denied")]]

      cases.each do |records|
        result = HoneycombRegistry::Catalog.build(root: root,
                                                  evidence_path: write_evidence(root, records))
        refute result.findings.errors?, result.findings.to_h.inspect
        assert_empty result.document.fetch("entries")
      end
    end
  end

  def test_dual_current_approval_projects_one_consumer_entry
    in_tmpdir do |root|
      package = canonical_package(root)
      record = evidence_record(package)
      evidence = write_evidence(root, [record])
      result = HoneycombRegistry::Catalog.build(root: root, evidence_path: evidence)

      refute result.findings.errors?, result.findings.to_h.inspect
      entry = result.document.fetch("entries").fetch(0)
      schema = JSON.parse(File.read(File.join(ROOT, "schemas", "catalog-v2.json")))
      assert_equal schema.dig("$defs", "entry", "required").sort, entry.keys.sort
      assert_equal "example", entry["name"]
      assert_equal "1.0.0", entry["latest_version"]
      assert_equal "hive workflow install honeycomb/example", entry["install_command"]
      assert_equal "a" * 40, entry["source_sha"]
      assert_equal "d" * 40, entry.dig("listing_approval", "head_sha")
      assert_equal ["registry-reviewer-1"], entry.dig("listing_approval", "approved_by")
      assert_equal "independent", entry.dig("listing_approval", "reviews", 0, "authority")
      assert_equal "community", entry["release_tier"]
      assert_equal "community", entry["current_tier"]
      assert_equal "listed", entry["state"]
      assert entry["discoverable"]
      assert_equal "https://github.com/ivankuznetsov/honeycomb/tree/main/packages/example/1.0.0",
                   entry["package_url"]
      refute_includes entry["package_url"], record.dig("lint", "head_sha")
      assert_equal "https://example.test/reviews/example-1.0.0-1", entry["reviews_url"]
      assert_nil entry["community_reviews_url"]
      refute entry.key?("files")
    end
  end

  def test_community_review_url_is_distinct_and_only_emitted_for_existing_records
    in_tmpdir do |root|
      package = canonical_package(root)
      record = evidence_record(package)
      evidence = write_evidence(root, [record])
      directory = File.join(root, "reviews", "example", "1.0.0")
      FileUtils.mkdir_p(directory)

      empty = HoneycombRegistry::Catalog.build(root: root, evidence_path: evidence)
      assert_nil empty.document.dig("entries", 0, "community_reviews_url")

      write_community_review(root, package, record, reviewer: "reviewer")
      populated = HoneycombRegistry::Catalog.build(root: root, evidence_path: evidence)
      assert_equal "https://github.com/ivankuznetsov/honeycomb/tree/main/reviews/example/1.0.0",
                   populated.document.dig("entries", 0, "community_reviews_url")
      assert_equal "https://example.test/reviews/example-1.0.0-1",
                   populated.document.dig("entries", 0, "reviews_url")
    end
  end


  def test_malformed_community_review_aborts_catalog_generation
    in_tmpdir do |root|
      package = canonical_package(root)
      evidence = write_evidence(root, [evidence_record(package)])
      path = File.join(root, "reviews", "example", "1.0.0", "reviewer.md")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "not a review\n")

      result = HoneycombRegistry::Catalog.build(root: root, evidence_path: evidence)

      assert_nil result.document
      assert_includes result.findings.codes, "review.invalid"
    end
  end

  def test_stale_or_mismatched_evidence_aborts
    in_tmpdir do |root|
      package = canonical_package(root)
      record = evidence_record(package)
      record["lint"]["release_sha256"] = "f" * 64
      record["approvals"][0]["release_sha256"] = "f" * 64
      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [record])
      )
      assert result.findings.errors?
      assert_includes result.findings.codes, "evidence.stale_release"
      assert_nil result.bytes
    end

    in_tmpdir do |root|
      package = canonical_package(root)
      record = evidence_record(package)
      record["approvals"][0]["head_sha"] = "e" * 40
      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [record])
      )
      assert_includes result.findings.codes, "evidence.head_mismatch"
    end
  end

  def test_lifecycle_controls_discovery_latest_and_exact_resolution_without_deleting_history
    in_tmpdir do |root|
      listed = canonical_package(root, version: "1.0.0")
      hidden = canonical_package(root, version: "1.1.0")
      yanked = canonical_package(root, version: "1.2.0")
      revoked = canonical_package(root, version: "1.3.0")
      state_history = lambda do |state, at|
        [{
          "kind" => "state", "from" => "listed", "to" => state,
          "changed_at" => at, "actor" => "registry-maintainer",
          "reason" => "Lifecycle test", "url" => "https://example.test/history/#{state}"
        }]
      end
      records = [
        evidence_record(listed),
        evidence_record(hidden, state: "soft_hidden", history: state_history.call("soft_hidden", "2026-07-17T08:00:00Z")),
        evidence_record(yanked, state: "yanked", history: state_history.call("yanked", "2026-07-17T09:00:00Z")),
        evidence_record(
          revoked, state: "revoked", history: state_history.call("revoked", "2026-07-17T10:00:00Z"),
          advisories: [{
            "id" => "HC-2026-001", "title" => "Revoked test release", "severity" => "high",
            "url" => "https://example.test/advisories/HC-2026-001",
            "published_at" => "2026-07-17T10:00:00Z"
          }]
        )
      ]

      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, records)
      )

      refute result.findings.errors?, result.findings.to_h.inspect
      assert_equal %w[1.0.0 1.1.0 1.2.0 1.3.0], result.document["entries"].map { |entry| entry["version"] }
      assert_equal ["1.0.0"], HoneycombRegistry::Catalog.discovery(result.document).map { |entry| entry["version"] }
      assert_equal "1.0.0", HoneycombRegistry::Catalog.resolve(result.document, name: "example")["version"]
      assert_equal "1.0.0", result.document["entries"].first["latest_version"]
      assert_equal "1.1.0", HoneycombRegistry::Catalog.resolve(result.document, name: "example", version: "1.1.0")["version"]
      assert_equal "1.2.0", HoneycombRegistry::Catalog.resolve(result.document, name: "example", version: "1.2.0")["version"]
      error = assert_raises(HoneycombRegistry::Catalog::Revoked) do
        HoneycombRegistry::Catalog.resolve(result.document, name: "example", version: "1.3.0")
      end
      assert_equal "HC-2026-001", error.advisories.first.fetch("id")
    end
  end

  def test_high_risk_independent_authority_requires_two_approvals_and_owner_authority_is_explicit
    in_tmpdir do |root|
      package = canonical_package(root)
      workflow = File.join(package.path, "workflow.yml")
      File.write(workflow, File.read(workflow).sub("permissions: read-only", "permissions: yolo"))
      generated = HoneycombRegistry::Manifest.generate(package)
      refute generated.findings.errors?, generated.findings.to_h.inspect
      one = evidence_record(package, approval_count: 1)

      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [one])
      )
      refute result.findings.errors?, result.findings.to_h.inspect
      assert_empty result.document.fetch("entries")

      two = evidence_record(package, approval_count: 2)
      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [two])
      )
      refute result.findings.errors?, result.findings.to_h.inspect
      assert_equal %w[registry-reviewer-1 registry-reviewer-2],
                   result.document.dig("entries", 0, "listing_approval", "approved_by")
      assert_equal %w[independent independent],
                   result.document.dig("entries", 0, "listing_approval", "reviews").map { |review| review.fetch("authority") }

      owner = evidence_record(package, approval_count: 1, approval_authority: "repository_owner")
      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [owner])
      )
      refute result.findings.errors?, result.findings.to_h.inspect
      assert_equal "repository_owner",
                   result.document.dig("entries", 0, "listing_approval", "reviews", 0, "authority")
    end
  end

  def test_verified_evidence_binds_archive_signature_attestation_and_tier_history
    in_tmpdir do |root|
      package = canonical_package(root)
      manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
      verification = {
        "archive_sha256" => HoneycombRegistry::ReleaseVerification.archive_sha256(manifest),
        "signature" => {
          "identity" => "https://github.com/hive-sh/honeycomb/.github/workflows/release.yml@refs/tags/v1.0.0",
          "issuer" => "https://token.actions.githubusercontent.com",
          "url" => "https://search.sigstore.dev/entry/123"
        },
        "attestation" => {
          "repository" => "hive-sh/honeycomb",
          "workflow" => "hive-sh/honeycomb/.github/workflows/release.yml@refs/tags/v1.0.0",
          "url" => "https://github.com/hive-sh/honeycomb/attestations/123"
        },
        "verified_at" => "2026-07-16T12:00:00Z"
      }
      history = [{
        "kind" => "tier", "from" => "verified", "to" => "community",
        "changed_at" => "2026-07-17T08:00:00Z", "actor" => "registry-maintainer",
        "reason" => "Signer no longer meets current policy",
        "url" => "https://example.test/history/demotion"
      }]
      record = evidence_record(
        package, release_tier: "verified", current_tier: "community",
        verification: verification, history: history
      )

      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [record])
      )
      refute result.findings.errors?, result.findings.to_h.inspect
      assert_equal "verified", result.document.dig("entries", 0, "release_tier")
      assert_equal "community", result.document.dig("entries", 0, "current_tier")
      assert_equal history, result.document.dig("entries", 0, "history")

      record["verification"]["archive_sha256"] = "f" * 64
      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [record])
      )
      assert_includes result.findings.codes, "evidence.verification_digest_mismatch"

      record = evidence_record(package)
      record["permission_risk"] = "moderate"
      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [record])
      )
      assert_includes result.findings.codes, "evidence.permission_risk_mismatch"
    end
  end

  def test_multiple_versions_share_semver_latest_and_build_ambiguity_fails
    in_tmpdir do |root|
      first = canonical_package(root)
      prerelease = canonical_package(root, version: "1.1.0-rc.1")
      stable = canonical_package(root, version: "1.1.0")
      records = [first, prerelease, stable].map { |package| evidence_record(package) }

      result = HoneycombRegistry::Catalog.build(root: root,
                                                evidence_path: write_evidence(root, records))
      refute result.findings.errors?, result.findings.to_h.inspect
      assert_equal %w[1.0.0 1.1.0-rc.1 1.1.0], result.document["entries"].map { |entry| entry["version"] }
      assert_equal ["1.1.0"], result.document["entries"].map { |entry| entry["latest_version"] }.uniq
    end

    in_tmpdir do |root|
      one = canonical_package(root, version: "1.0.0+one")
      two = canonical_package(root, version: "1.0.0+two")
      records = [one, two].map { |package| evidence_record(package) }
      result = HoneycombRegistry::Catalog.build(root: root,
                                                evidence_path: write_evidence(root, records))
      assert result.findings.errors?
      assert_includes result.findings.codes, "catalog.ambiguous_latest"
    end
  end

  def test_invalid_package_aborts_even_when_evidence_would_omit_it
    in_tmpdir do |root|
      package = canonical_package(root)
      File.write(File.join(package.path, "extra.txt"), "unrecorded")
      result = HoneycombRegistry::Catalog.build(root: root,
                                                evidence_path: write_evidence(root, []))
      assert result.findings.errors?
      assert_nil result.bytes
    end
  end
end
