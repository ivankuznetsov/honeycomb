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

  def evidence_record(package, lint: "pass", approval: "approved", head: "d" * 40)
    manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
    release = manifest.fetch("release_sha256")
    {
      "name" => package.name,
      "version" => package.version,
      "tier" => "reviewed",
      "lint" => lint == "pending" ? {"status" => "pending"} : {
        "status" => lint,
        "release_sha256" => release,
        "head_sha" => head,
        "checked_at" => "2026-07-16T10:00:00Z"
      },
      "approval" => approval == "pending" ? {"status" => "pending"} : {
        "status" => approval,
        "release_sha256" => release,
        "head_sha" => head,
        "reviewer" => "registry-reviewer",
        "reviewed_at" => "2026-07-16T11:00:00Z",
        "review_url" => "https://example.test/reviews/#{package.name}-#{package.version}"
      }
    }
  end

  def write_evidence(root, records)
    path = File.join(root, "evidence.json")
    File.write(path, JSON.pretty_generate({
      "schema" => "honeycomb-listing-evidence/v1", "records" => records
    }) + "\n")
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
      evidence = write_evidence(root, [evidence_record(package)])
      result = HoneycombRegistry::Catalog.build(root: root, evidence_path: evidence)

      refute result.findings.errors?, result.findings.to_h.inspect
      entry = result.document.fetch("entries").fetch(0)
      assert_equal "example", entry["name"]
      assert_equal "1.0.0", entry["latest_version"]
      assert_equal "hive workflow install honeycomb/example", entry["install_command"]
      assert_equal "a" * 40, entry["source_sha"]
      assert_equal "d" * 40, entry.dig("listing_approval", "head_sha")
      assert_equal "https://example.test/reviews/example-1.0.0", entry["reviews_url"]
      assert_includes entry["package_url"], "/tree/#{"d" * 40}/packages/example/1.0.0"
      refute entry.key?("files")
    end
  end

  def test_stale_or_mismatched_evidence_aborts
    in_tmpdir do |root|
      package = canonical_package(root)
      record = evidence_record(package)
      record["lint"]["release_sha256"] = "f" * 64
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
      record["approval"]["head_sha"] = "e" * 40
      result = HoneycombRegistry::Catalog.build(
        root: root, evidence_path: write_evidence(root, [record])
      )
      assert_includes result.findings.codes, "evidence.head_mismatch"
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
