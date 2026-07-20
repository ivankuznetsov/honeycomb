# frozen_string_literal: true

require_relative "test_helper"

class ManagedRepairProvenanceTest < Minitest::Test
  PACKAGES = %w[reviewer-panel root-cause-repair].freeze

  def test_committed_manifests_bind_the_preserved_registry_source_bytes
    PACKAGES.each do |name|
      root = File.join(ROOT, "packages", name, "1.0.0")
      package = HoneycombRegistry::Package.new(root, root: ROOT)
      manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
      revision = manifest.dig("source", "revision")

      assert_includes manifest.dig("source", "url"), revision, name
      assert_equal "registry-original", manifest.dig("x-provenance", "kind"), name
      assert git_success?("merge-base", "--is-ancestor", revision, "HEAD"), name

      manifest.dig("x-provenance", "source_paths").each do |path|
        source, stderr, status = Open3.capture3(
          "git", "show", "#{revision}:packages/#{name}/1.0.0/#{path}", chdir: ROOT
        )
        assert status.success?, "#{name}/#{path}: #{stderr}"
        assert_equal File.binread(File.join(root, path)), source.b, "#{name}/#{path}"
      end

      checked = HoneycombRegistry::Manifest.check(package)
      refute checked.findings.errors?, checked.findings.to_h.inspect
    end
  end

  private

  def git_success?(*arguments)
    _stdout, _stderr, status = Open3.capture3("git", *arguments, chdir: ROOT)
    status.success?
  end
end
