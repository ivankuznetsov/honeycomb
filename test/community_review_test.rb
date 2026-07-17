# frozen_string_literal: true

require_relative "test_helper"

class CommunityReviewTest < Minitest::Test
  HEAD = "d" * 40

  def install_catalog(root)
    package_path = install_valid_fixture(root)
    package = HoneycombRegistry::Package.new(package_path, root: root)
    result = HoneycombRegistry::Manifest.generate(package)
    raise result.findings.to_h.inspect if result.findings.errors?
    manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
    catalog = {
      "schema" => HoneycombRegistry::Catalog::SCHEMA,
      "entries" => [{
        "name" => package.name, "version" => package.version,
        "source_sha" => manifest.dig("source", "revision"),
        "listing_approval" => {
          "release_sha256" => manifest.fetch("release_sha256"), "head_sha" => HEAD
        }
      }]
    }
    File.write(File.join(root, "catalog.json"), JSON.pretty_generate(catalog))
    manifest
  end

  def review_text(manifest, reviewer: "alice-reviewer")
    <<~MARKDOWN
      ---
      reviewer: "#{reviewer}"
      name: "example"
      version: "1.0.0"
      source_sha: "#{manifest.dig("source", "revision")}"
      release_sha256: "#{manifest.fetch("release_sha256")}"
      head_sha: "#{HEAD}"
      reviewed_at: "2026-07-17"
      verdict: "approve"
      conflict_of_interest: "none"
      ---
      # Community review

      ## Scope reviewed

      I reviewed every package file.

      ## Permission observations

      The declared permissions match the observed behavior.

      ## Findings

      None observed.

      ## Rationale

      The package and its declared behavior agree.
    MARKDOWN
  end

  def git(root, *arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: root)
    raise [stdout, stderr].join("\n") unless status.success?
    stdout.strip
  end

  def test_validates_path_shape_record_and_canonical_package_catalog_bindings
    in_tmpdir do |root|
      manifest = install_catalog(root)
      path = "reviews/example/1.0.0/alice-reviewer.md"
      absolute = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, review_text(manifest))

      record = HoneycombRegistry::CommunityReview.validate(root: root, path: path)
      assert_equal "approve", record.fetch("verdict")
      assert_equal [absolute], Dir[File.join(root, "reviews", "**", "*.md")]
      HoneycombRegistry::CommunityReview.validate_all(root: root)

      File.write(absolute, review_text(manifest).sub(HEAD, "e" * 40))
      error = assert_raises(HoneycombRegistry::CommunityReview::Invalid) do
        HoneycombRegistry::CommunityReview.validate(root: root, path: path)
      end
      assert_includes error.message, "listed review head"
    end
  end

  def test_rejects_impersonation_and_noncanonical_paths
    in_tmpdir do |root|
      manifest = install_catalog(root)
      path = "reviews/example/1.0.0/alice-reviewer.md"

      assert_raises(HoneycombRegistry::CommunityReview::Invalid) do
        HoneycombRegistry::CommunityReview.validate(
          root: root, path: path, text: review_text(manifest), expected_reviewer: "mallory"
        )
      end
      assert_raises(HoneycombRegistry::CommunityReview::Invalid) do
        HoneycombRegistry::CommunityReview.validate(
          root: root, path: "reviews/example/1.0.0/nested/alice.md", text: review_text(manifest)
        )
      end
    end
  end

  def test_exact_sha_validation_reads_untrusted_objects_without_checkout
    in_tmpdir do |root|
      manifest = install_catalog(root)
      git(root, "init", "-q")
      git(root, "config", "user.name", "Review Test")
      git(root, "config", "user.email", "review@example.test")
      git(root, "add", ".")
      git(root, "-c", "commit.gpgsign=false", "commit", "-qm", "base")
      base = git(root, "rev-parse", "HEAD")

      path = "reviews/example/1.0.0/alice-reviewer.md"
      absolute = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(absolute))
      File.write(absolute, review_text(manifest))
      git(root, "add", path)
      git(root, "-c", "commit.gpgsign=false", "commit", "-qm", "review")
      head = git(root, "rev-parse", "HEAD")

      assert_equal [path], HoneycombRegistry::CommunityReview.validate_changed(
        root: root, base_sha: base, head_sha: head, expected_reviewer: "alice-reviewer"
      )
      assert_raises(HoneycombRegistry::CommunityReview::Invalid) do
        HoneycombRegistry::CommunityReview.validate_changed(
          root: root, base_sha: base, head_sha: head, expected_reviewer: "mallory"
        )
      end

      File.write(absolute, review_text(manifest).sub(HEAD, "e" * 40))
      catalog_path = File.join(root, "catalog.json")
      File.write(catalog_path, File.read(catalog_path).sub(HEAD, "e" * 40))
      git(root, "add", path, "catalog.json")
      git(root, "-c", "commit.gpgsign=false", "commit", "-qm", "forge submitted catalog")
      forged = git(root, "rev-parse", "HEAD")
      error = assert_raises(HoneycombRegistry::CommunityReview::Invalid) do
        HoneycombRegistry::CommunityReview.validate_changed(
          root: root, base_sha: base, head_sha: forged, expected_reviewer: "alice-reviewer"
        )
      end
      assert_includes error.message, "listed review head"
    end
  end
end
