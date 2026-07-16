# frozen_string_literal: true

require_relative "test_helper"

class HiveCompatibilityTest < Minitest::Test
  Runtime = HoneycombRegistry::HiveCompatibility::Runtime

  class RecordingParser
    class << self
      attr_accessor :data, :path, :failure

      def parse_hash(data, path:)
        raise failure if failure

        self.data = data
        self.path = path
        true
      end
    end
  end

  def with_package
    in_tmpdir do |root|
      package = HoneycombRegistry::Package.new(install_valid_fixture(root), root: root)
      manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
      workflow = HoneycombRegistry::SafeYAML.load_file(File.join(package.path, "workflow.yml"))
      yield package, manifest, workflow
    end
  end

  def test_absence_warns_locally_and_errors_when_strict
    with_package do |package, manifest, workflow|
      local = HoneycombRegistry::HiveCompatibility.check(
        package, manifest, workflow: workflow, loader: -> { nil }
      )
      refute local.errors?
      assert_equal "warning", local.sorted.first.severity
      assert_includes local.codes, "hive.missing"

      strict = HoneycombRegistry::HiveCompatibility.check(
        package, manifest, workflow: workflow, require_hive: true, loader: -> { nil }
      )
      assert strict.errors?
      assert_includes strict.codes, "hive.missing"
    end
  end

  def test_old_runtime_and_parser_rejection_are_errors
    with_package do |package, manifest, workflow|
      old = Runtime.new(version: "0.0.9", parser: RecordingParser)
      findings = HoneycombRegistry::HiveCompatibility.check(
        package, manifest, workflow: workflow, loader: -> { old }
      )
      assert findings.errors?
      assert_includes findings.codes, "hive.version_too_old"

      RecordingParser.failure = RuntimeError.new("descriptor rejected")
      current = Runtime.new(version: "1.0.0", parser: RecordingParser)
      findings = HoneycombRegistry::HiveCompatibility.check(
        package, manifest, workflow: workflow, loader: -> { current }
      )
      assert findings.errors?
      assert_includes findings.codes, "hive.parser_rejected"
    ensure
      RecordingParser.failure = nil
    end
  end

  def test_compatible_runtime_parses_with_synthetic_name_in_package_directory
    with_package do |package, manifest, workflow|
      runtime = Runtime.new(version: "1.2.3", parser: RecordingParser)
      findings = HoneycombRegistry::HiveCompatibility.check(
        package, manifest, workflow: workflow, loader: -> { runtime }
      )

      refute findings.errors?, findings.to_h.inspect
      assert_equal workflow, RecordingParser.data
      assert_equal File.join(package.path, "example.yml"), RecordingParser.path
    end
  end
end
