# frozen_string_literal: true

require_relative "test_helper"

class SchemaTest < Minitest::Test
  def valid_manifest
    {
      "schema" => "honeycomb-manifest/v1",
      "name" => "example",
      "version" => "1.0.0",
      "description" => "Example honeycomb",
      "author" => {"name" => "Example Author", "url" => "https://example.test/author"},
      "license" => "MIT",
      "hive_min_version" => "0.1.0",
      "source" => {"url" => "https://example.test/source", "revision" => "a" * 40},
      "permissions" => {
        "risk" => "low",
        "capabilities" => ["filesystem-read"],
        "network_hosts" => [],
        "filesystem_read" => ["repository"],
        "filesystem_write" => [],
        "secrets" => []
      },
      "files" => {"packages/example/1.0.0/README.md" => "b" * 64},
      "release_sha256" => "c" * 64,
      "x-registry-note" => {"enabled" => true}
    }
  end

  def test_accepts_complete_manifest_and_safe_extension
    findings = HoneycombRegistry::Schema.validate_manifest(valid_manifest)
    refute findings.errors?, findings.to_h.inspect
  end

  def test_rejects_missing_unknown_and_nested_unknown_keys
    missing = valid_manifest.tap { |manifest| manifest.delete("license") }
    assert_includes HoneycombRegistry::Schema.validate_manifest(missing).codes,
                    "schema.missing_key"

    unknown = valid_manifest.merge("surprise" => true)
    assert_includes HoneycombRegistry::Schema.validate_manifest(unknown).codes,
                    "schema.unknown_key"

    nested = valid_manifest
    nested["author"] = nested["author"].merge("email" => "author@example.test")
    assert_includes HoneycombRegistry::Schema.validate_manifest(nested).codes,
                    "schema.unknown_key"
  end

  def test_validates_names_urls_hashes_licenses_and_versions
    mutations = {
      "name" => "Bad_Name",
      "license" => "Definitely-Not-SPDX",
      "hive_min_version" => "01.0.0",
      "release_sha256" => "ABC",
      "author" => {"name" => "Author", "url" => "javascript:alert(1)"},
      "source" => {"url" => "relative/path", "revision" => "not-a-sha"}
    }

    mutations.each do |key, value|
      manifest = valid_manifest.merge(key => value)
      assert HoneycombRegistry::Schema.validate_manifest(manifest).errors?, key
    end
  end

  def test_metadata_validation_allows_generator_owned_fields_to_be_absent
    metadata = valid_manifest.reject do |key, _value|
      %w[permissions files release_sha256].include?(key)
    end

    refute HoneycombRegistry::Schema.validate_metadata(metadata).errors?
  end

  def test_enforces_name_boundaries
    %w[ab -abc abc-].each do |name|
      assert HoneycombRegistry::Schema.validate_manifest(valid_manifest.merge("name" => name)).errors?
    end

    name = "a" + ("b" * 62) + "c"
    assert_equal 64, name.length
    manifest = valid_manifest.merge(
      "name" => name,
      "files" => {"packages/#{name}/1.0.0/README.md" => "b" * 64}
    )
    refute HoneycombRegistry::Schema.validate_manifest(manifest).errors?
  end

  def test_checked_in_catalog_and_listing_evidence_schemas_match_runtime_versions
    listing = JSON.parse(File.read(File.join(ROOT, "schemas", "listing-evidence-v1.json")))
    catalog = JSON.parse(File.read(File.join(ROOT, "schemas", "catalog-v1.json")))

    assert_equal HoneycombRegistry::ListingEvidence::SCHEMA,
                 listing.dig("properties", "schema", "const")
    assert_equal HoneycombRegistry::Catalog::SCHEMA,
                 catalog.dig("properties", "schema", "const")
    assert_equal HoneycombRegistry::ListingEvidence::STATES,
                 listing.dig("$defs", "record", "properties", "state", "enum")
    assert_equal HoneycombRegistry::ListingEvidence::TIERS,
                 listing.dig("$defs", "record", "properties", "release_tier", "enum")
    fixture = JSON.parse(File.read(fixture_path("listing-evidence", "passing.json")))
    assert_equal listing.dig("$defs", "record", "required").sort,
                 fixture.fetch("records").first.keys.sort
  end
end
