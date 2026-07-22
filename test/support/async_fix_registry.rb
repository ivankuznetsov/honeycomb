# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "psych"

module AsyncFixRegistrySupport
  ASYNC_FIX_PACKAGE_NAME = "async-fix"
  ASYNC_FIX_TEST_VERSION = "0.0.0"
  ASYNC_FIX_CANDIDATE_ROOT = File.join(ROOT, "candidates", ASYNC_FIX_PACKAGE_NAME)

  AsyncFixRegistry = Data.define(
    :root, :package, :manifest, :source_revision, :release_revision, :catalog_commit
  )

  def with_async_fix_registry
    Dir.mktmpdir("honeycomb-async-fix-registry") do |root|
      yield build_async_fix_registry(root)
    ensure
      FileUtils.chmod_R(0o700, root) if File.exist?(root)
    end
  end

  def build_async_fix_registry(root)
    async_fix_git!(root, "init", "-q", "-b", "main")
    async_fix_git!(root, "config", "user.email", "async-fix@example.test")
    async_fix_git!(root, "config", "user.name", "Async Fix fixture")

    destination = File.join(
      root, "packages", ASYNC_FIX_PACKAGE_NAME, ASYNC_FIX_TEST_VERSION
    )
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp_r(ASYNC_FIX_CANDIDATE_ROOT, destination)
    FileUtils.rm_f(File.join(destination, "manifest.yml"))
    async_fix_git!(root, "add", "packages")
    async_fix_git!(root, "commit", "-qm", "ephemeral async-fix behavior source")
    source_revision = async_fix_git!(root, "rev-parse", "HEAD").strip

    package = HoneycombRegistry::Package.new(destination, root: root)
    File.write(package.manifest_path, Psych.dump(async_fix_manifest_metadata(source_revision)))
    generated = HoneycombRegistry::Manifest.generate(package)
    raise generated.findings.to_h.inspect if generated.findings.errors?

    async_fix_git!(root, "add", package.relative_manifest_path)
    async_fix_git!(root, "commit", "-qm", "ephemeral async-fix manifest")
    release_revision = async_fix_git!(root, "rev-parse", "HEAD").strip

    catalog = {
      "schema" => "honeycomb-catalog/v2",
      "entries" => [
        async_fix_catalog_entry(
          generated.document,
          source_revision: source_revision,
          review_head: release_revision
        )
      ]
    }
    File.binwrite(
      File.join(root, "catalog.json"),
      HoneycombRegistry::CanonicalJSON.dump(catalog)
    )
    async_fix_git!(root, "add", "catalog.json")
    async_fix_git!(root, "commit", "-qm", "ephemeral async-fix catalog")
    catalog_commit = async_fix_git!(root, "rev-parse", "HEAD").strip

    AsyncFixRegistry.new(
      root: root,
      package: package,
      manifest: generated.document,
      source_revision: source_revision,
      release_revision: release_revision,
      catalog_commit: catalog_commit
    )
  end

  def async_fix_manifest_metadata(source_revision)
    {
      "schema" => "honeycomb-manifest/v1",
      "name" => ASYNC_FIX_PACKAGE_NAME,
      "version" => ASYNC_FIX_TEST_VERSION,
      "description" => "Focused one-agent defect repair with a controller-owned draft PR handoff",
      "author" => {
        "name" => "Honeycomb maintainers",
        "url" => "https://example.test/honeycomb"
      },
      "license" => "MIT",
      "hive_min_version" => "0.6.0",
      "source" => {
        "url" => "https://example.test/honeycomb/commit/#{source_revision}",
        "revision" => source_revision
      },
      "x-hive" => {
        "tools" => [],
        "prompt_assets" => [{"path" => "assets/fix-report-contract.md"}],
        "optional_inputs" => [],
        "mapping_recommendations" => [
          {"slot" => "stages.fix", "effort" => "medium"}
        ]
      },
      "x-security" => {
        "network_host_reasons" => {},
        "suppressions" => []
      }
    }
  end

  def async_fix_catalog_entry(manifest, source_revision:, review_head:)
    permissions = manifest.fetch("permissions")
    reviewer = "fixture-owner"
    {
      "name" => ASYNC_FIX_PACKAGE_NAME,
      "version" => ASYNC_FIX_TEST_VERSION,
      "latest_version" => ASYNC_FIX_TEST_VERSION,
      "description" => manifest.fetch("description"),
      "release_tier" => "community",
      "current_tier" => "community",
      "permission_risk" => permissions.fetch("risk"),
      "state" => "listed",
      "discoverable" => true,
      "exact_resolution" => "allowed",
      "verification" => nil,
      "history" => [],
      "advisories" => [],
      "author" => manifest.fetch("author"),
      "license" => manifest.fetch("license"),
      "hive_min_version" => manifest.fetch("hive_min_version"),
      "permissions" => permissions,
      "install_command" => "hive workflow install honeycomb/#{ASYNC_FIX_PACKAGE_NAME}",
      "package_url" => "https://example.test/packages/#{ASYNC_FIX_PACKAGE_NAME}/#{ASYNC_FIX_TEST_VERSION}",
      "reviews_url" => "https://example.test/reviews/#{ASYNC_FIX_PACKAGE_NAME}/#{ASYNC_FIX_TEST_VERSION}",
      "community_reviews_url" => nil,
      "source_sha" => source_revision,
      "listing_approval" => {
        "release_sha256" => manifest.fetch("release_sha256"),
        "head_sha" => review_head,
        "lint_checked_at" => "2026-07-22T00:00:00Z",
        "approved_by" => [reviewer],
        "approved_at" => "2026-07-22T00:00:01Z",
        "reviews" => [{
          "reviewer" => reviewer,
          "authority" => "repository_owner",
          "reviewed_at" => "2026-07-22T00:00:01Z",
          "review_url" => "https://example.test/reviews/async-fix/#{reviewer}",
          "evidence_digest" => Digest::SHA256.hexdigest("async-fix:#{reviewer}")
        }]
      }
    }
  end

  def async_fix_git!(repository, *arguments)
    stdout, stderr, status = Open3.capture3("git", "-C", repository, *arguments)
    raise "git #{arguments.join(' ')} failed: #{stderr}" unless status.success?

    stdout
  end
end
