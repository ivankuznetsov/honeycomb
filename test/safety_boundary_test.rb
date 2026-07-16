# frozen_string_literal: true

require_relative "test_helper"

class SafetyBoundaryTest < Minitest::Test
  def canonical_package(root)
    package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
    HoneycombRegistry::Manifest.generate(package)
    package
  end

  def test_absolute_traversal_and_backslash_manifest_keys_never_enter_the_hash_boundary
    ["/tmp/outside", "packages/example/1.0.0/../outside", "packages\\example\\outside"].each do |unsafe|
      in_tmpdir do |root|
        package = canonical_package(root)
        manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
        manifest["files"][unsafe] = "f" * 64
        File.binwrite(package.manifest_path, HoneycombRegistry::CanonicalYAML.dump_manifest(manifest))

        findings = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
        assert findings.errors?, unsafe
        assert_includes findings.codes, "schema.invalid_file_path"
      end
    end
  end

  def test_symlinks_special_files_and_ambiguous_names_fail_closed
    in_tmpdir do |root|
      package = canonical_package(root)
      sentinel = File.join(root, "sentinel")
      File.write(sentinel, "outside")
      File.symlink(sentinel, File.join(package.path, "instructions", "escape"))
      findings = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
      assert_includes findings.codes, "package.symlink"
    end

    in_tmpdir do |root|
      package = canonical_package(root)
      fifo = File.join(package.path, "instructions", "pipe")
      assert system("mkfifo", fifo)
      findings = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
      assert_includes findings.codes, "package.special_file"
    end

    in_tmpdir do |root|
      package = canonical_package(root)
      File.write(File.join(package.path, "instructions", "é.txt"), "one")
      File.write(File.join(package.path, "instructions", "e\u0301.txt"), "two")
      findings = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
      assert_includes findings.codes, "package.duplicate_path"
    end
  end

  def test_unsafe_manifest_yaml_is_rejected_without_replacement
    in_tmpdir do |root|
      package = canonical_package(root)
      path = package.manifest_path
      File.binwrite(path, "schema: &schema honeycomb-manifest/v1\ncopy: *schema\n")
      before = File.binread(path)

      findings = HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
      assert_includes findings.codes, "yaml.alias"
      assert_equal before, File.binread(path)
    end
  end
end
