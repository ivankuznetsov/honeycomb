# frozen_string_literal: true

require_relative "test_helper"

class ManifestTest < Minitest::Test
  def test_builds_the_checked_in_canonical_golden_bytes
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      result = HoneycombRegistry::Manifest.build(package)

      refute result.findings.errors?, result.findings.to_h.inspect
      assert_equal File.binread(fixture_path("expected", "manifest.yml")), result.bytes
      assert_match(/\Arelease_sha256: ["0-9a-f]/, result.bytes.lines.grep(/release_sha256/).first)
    end
  end

  def test_generation_is_atomic_repeatable_and_check_is_read_only
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      first = HoneycombRegistry::Manifest.generate(package)
      refute first.findings.errors?, first.findings.to_h.inspect
      bytes = File.binread(package.manifest_path)

      second = HoneycombRegistry::Manifest.generate(package)
      refute second.findings.errors?, second.findings.to_h.inspect
      assert_equal bytes, File.binread(package.manifest_path)

      checked = HoneycombRegistry::Manifest.check(package)
      refute checked.findings.errors?, checked.findings.to_h.inspect
      assert_equal bytes, File.binread(package.manifest_path)
    end
  end

  def test_check_detects_payload_drift_without_rewriting_manifest
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      HoneycombRegistry::Manifest.generate(package)
      manifest_before = File.binread(package.manifest_path)
      File.open(File.join(package.path, "README.md"), "a") { |file| file << "changed\n" }

      result = HoneycombRegistry::Manifest.check(package)
      assert result.findings.errors?
      assert_includes result.findings.codes, "manifest.drift"
      assert_equal manifest_before, File.binread(package.manifest_path)
    end
  end

  def test_external_community_reviews_do_not_change_the_package_fingerprint
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      before = HoneycombRegistry::Manifest.build(package)
      refute before.findings.errors?, before.findings.to_h.inspect

      review_path = File.join(root, "reviews", package.name, package.version, "reviewer.md")
      FileUtils.mkdir_p(File.dirname(review_path))
      File.write(review_path, "---\nreviewer: reviewer\n---\n")

      after = HoneycombRegistry::Manifest.build(package)
      refute after.findings.errors?, after.findings.to_h.inspect
      assert_equal before.bytes, after.bytes
      assert_equal before.document.fetch("release_sha256"), after.document.fetch("release_sha256")
      refute after.document.fetch("files").keys.any? { |path| path.start_with?("reviews/") }
    end
  end

  def test_failure_preserves_existing_manifest
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      original = File.binread(package.manifest_path)
      workflow = File.join(package.path, "workflow.yml")
      File.write(workflow, File.read(workflow).sub("read-only", "future-permission"))

      result = HoneycombRegistry::Manifest.generate(package)
      assert result.findings.errors?
      assert_equal original, File.binread(package.manifest_path)
    end
  end

  def test_identity_must_match_version_directory
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      path = package.manifest_path
      File.write(path, File.read(path).sub("version: 1.0.0", "version: 2.0.0"))

      result = HoneycombRegistry::Manifest.build(package)
      assert result.findings.errors?
      assert_includes result.findings.codes, "manifest.identity"
    end
  end

  def test_generation_rejects_instruction_paths_that_escape_the_package
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      sentinel = File.join(root, "outside.md")
      File.write(sentinel, "outside")
      workflow = File.join(package.path, "workflow.yml")
      File.write(workflow, File.read(workflow).sub("instructions/build.md", "../../../outside.md"))
      before = File.binread(package.manifest_path)

      result = HoneycombRegistry::Manifest.generate(package)
      assert result.findings.errors?
      assert_includes result.findings.codes, "package.invalid_instruction_path"
      assert_equal before, File.binread(package.manifest_path)
    end
  end

  def test_specialized_runtime_metadata_survives_generation_and_hashes_the_tool
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      tool_path = File.join(package.path, "tools", "analyze.rb")
      FileUtils.mkdir_p(File.dirname(tool_path))
      File.write(tool_path, "#!/usr/bin/env ruby\nputs :ok\n")
      File.chmod(0o755, tool_path)
      manifest_path = package.manifest_path
      File.write(
        manifest_path,
        File.read(manifest_path).sub(
          "x-hive:\n  tools: []\n  optional_inputs: []\n",
          <<~YAML
            x-hive:
              tools:
                - path: tools/analyze.rb
              mapping_recommendations:
                - slot: stages.build
                  effort: medium
              optional_inputs:
                - name: SEO_API_TOKEN
                  authorized_slots:
                    - stages.build
          YAML
        )
      )

      result = HoneycombRegistry::Manifest.build(package)

      refute result.findings.errors?, result.findings.to_h.inspect
      assert_equal [{"path" => "tools/analyze.rb"}], result.document.dig("x-hive", "tools")
      assert_equal [{"slot" => "stages.build", "effort" => "medium"}],
                   result.document.dig("x-hive", "mapping_recommendations")
      assert_equal ["stages.build"],
                   result.document.dig("x-hive", "optional_inputs", 0, "authorized_slots")
      assert result.document.fetch("files").key?("packages/example/1.0.0/tools/analyze.rb")
    end
  end
end
