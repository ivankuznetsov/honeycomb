# frozen_string_literal: true

require_relative "test_helper"

class ValidatorTest < Minitest::Test
  def canonical_package(root)
    package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
    result = HoneycombRegistry::Manifest.generate(package)
    raise result.findings.to_h.inspect if result.findings.errors?
    package
  end

  def validate_without_hive(package, require_hive: false)
    HoneycombRegistry::Validator.validate(
      package, require_hive: require_hive, hive_loader: -> { nil }
    )
  end

  def test_validates_canonical_package_read_only
    in_tmpdir do |root|
      package = canonical_package(root)
      before = Dir.glob(File.join(package.path, "**", "*"), File::FNM_DOTMATCH)
                  .reject { |path| [".", ".."].include?(File.basename(path)) }
                  .to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }

      findings = validate_without_hive(package)

      refute findings.errors?, findings.to_h.inspect
      assert_includes findings.codes, "hive.missing"
      after = before.transform_keys(&:itself).to_h do |path, _value|
        [path, File.file?(path) ? File.binread(path) : nil]
      end
      assert_equal before, after
    end
  end

  def test_detects_changed_missing_and_unrecorded_files
    mutations = {
      "changed" => lambda { |package|
        File.open(File.join(package.path, "README.md"), "a") { |file| file << "tampered\n" }
      },
      "missing" => ->(package) { FileUtils.rm(File.join(package.path, "README.md")) },
      "unrecorded" => ->(package) { File.write(File.join(package.path, "extra.txt"), "extra") }
    }
    expected = {
      "changed" => "integrity.digest_mismatch",
      "missing" => "integrity.missing_file",
      "unrecorded" => "integrity.unrecorded_file"
    }

    mutations.each do |name, mutation|
      in_tmpdir do |root|
        package = canonical_package(root)
        mutation.call(package)
        findings = validate_without_hive(package)
        assert findings.errors?, name
        assert_includes findings.codes, expected.fetch(name)
      end
    end
  end

  def test_detects_permission_fingerprint_and_canonical_byte_drift
    in_tmpdir do |root|
      package = canonical_package(root)
      path = package.manifest_path
      bytes = File.binread(path)
      File.binwrite(path, bytes.sub('risk: "low"', 'risk: "moderate"'))

      findings = validate_without_hive(package)
      assert findings.errors?
      assert_includes findings.codes, "permissions.drift"
      assert_includes findings.codes, "integrity.release_sha256"
    end

    in_tmpdir do |root|
      package = canonical_package(root)
      path = package.manifest_path
      File.binwrite(path, "# noncanonical\n" + File.binread(path))
      findings = validate_without_hive(package)
      assert_includes findings.codes, "manifest.noncanonical"
    end
  end

  def test_strict_hive_mode_turns_absence_into_validation_failure
    in_tmpdir do |root|
      package = canonical_package(root)
      findings = validate_without_hive(package, require_hive: true)
      assert findings.errors?
      assert_includes findings.codes, "hive.missing"
    end
  end
end
