# frozen_string_literal: true

require_relative "test_helper"

class PackageTest < Minitest::Test
  def test_discovers_exact_name_and_version_depth
    in_tmpdir do |root|
      package_path = install_valid_fixture(root)
      discovery = HoneycombRegistry::Package.discover(root)

      refute discovery.findings.errors?, discovery.findings.to_h.inspect
      assert_equal [package_path], discovery.packages.map(&:path)
      assert_equal "example", discovery.packages.first.name
      assert_equal "1.0.0", discovery.packages.first.version
    end
  end

  def test_enumerates_every_regular_file_except_root_manifest
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      inspection = package.inspect

      refute inspection.findings.errors?, inspection.findings.to_h.inspect
      assert_includes inspection.files, "packages/example/1.0.0/.registry-note"
      assert_includes inspection.files,
                      "packages/example/1.0.0/instructions/nested/context.txt"
      refute_includes inspection.files, "packages/example/1.0.0/manifest.yml"
    end
  end

  def test_rejects_paths_outside_packages_and_malformed_discovery_entries
    in_tmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "packages"))
      File.write(File.join(root, "packages", "unexpected.txt"), "bad")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p(outside)

      assert HoneycombRegistry::Package.discover(root).findings.errors?
      assert HoneycombRegistry::Package.new(outside, root: root).inspect.findings.errors?
    end
  end

  def test_rejects_symlinks_and_special_files_without_following_them
    in_tmpdir do |root|
      package_path = install_valid_fixture(root)
      sentinel = File.join(root, "sentinel")
      File.write(sentinel, "outside")
      File.symlink(sentinel, File.join(package_path, "instructions", "escape"))

      package = HoneycombRegistry::Package.new(package_path, root: root)
      inspection = package.inspect
      assert inspection.findings.errors?
      assert_includes inspection.findings.codes, "package.symlink"
    end
  end

  def test_requires_readme_workflow_and_nonempty_instructions
    in_tmpdir do |root|
      package_path = install_valid_fixture(root)
      FileUtils.rm(File.join(package_path, "README.md"))
      FileUtils.rm_rf(File.join(package_path, "instructions"))
      FileUtils.mkdir(File.join(package_path, "instructions"))

      inspection = HoneycombRegistry::Package.new(package_path, root: root).inspect
      assert inspection.findings.errors?
      assert_includes inspection.findings.codes, "package.missing_required"
      assert_includes inspection.findings.codes, "package.empty_instructions"
    end
  end
end
