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

  def managed_workflow
    {
      "id" => "example",
      "stages" => [
        {
          "name" => "draft", "kind" => "council", "state_file" => "draft.md",
          "instruction" => "instructions/build.md", "mapping_role" => "development",
          "mapping_contract" => "v1", "permissions" => "read-only",
          "reviewers" => [
            {
              "name" => "accuracy", "instruction" => "instructions/build.md",
              "mapping_role" => "reviewer", "mapping_contract" => "v1",
              "permissions" => "read-only"
            }
          ],
          "council" => {
            "revise" => {
              "instruction" => "instructions/build.md", "mapping_role" => "development",
              "mapping_contract" => "v1", "permissions" => "read-only"
            }
          }
        },
        {"name" => "done", "kind" => "terminal", "state_file" => "draft.md"}
      ]
    }
  end

  def managed_manifest(overrides = {})
    {
      "x-hive" => {
        "tools" => [],
        "optional_inputs" => []
      }
    }.merge(overrides)
  end

  def validate_contract(package, workflow: managed_workflow, manifest: managed_manifest)
    HoneycombRegistry::HiveCompatibility.validate_package_contract(
      package, manifest, workflow: workflow, inventory: package.inspect.files
    )
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

  def test_registry_contract_rejects_embedded_identity_at_every_actor_location
    with_package do |package, _manifest, _workflow|
      mutations = [
        ->(workflow, key) { workflow["stages"][0][key] = "forbidden" },
        ->(workflow, key) { workflow["stages"][0]["reviewers"][0][key] = "forbidden" },
        ->(workflow, key) { workflow["stages"][0]["council"]["revise"][key] = "forbidden" }
      ]

      %w[agent model effort].product(mutations).each do |key, mutation|
        workflow = Marshal.load(Marshal.dump(managed_workflow))
        mutation.call(workflow, key)
        findings = validate_contract(package, workflow: workflow)

        assert_includes findings.codes, "hive.embedded_identity", [key, findings.to_h]
      end
    end
  end

  def test_registry_contract_requires_explicit_mapping_and_permissions_for_every_actor
    with_package do |package, _manifest, _workflow|
      workflow = managed_workflow
      workflow["stages"][0].delete("permissions")
      workflow["stages"][0]["reviewers"][0]["mapping_role"] = "development"
      workflow["stages"][0]["council"]["revise"].delete("mapping_contract")

      findings = validate_contract(package, workflow: workflow)

      assert_includes findings.codes, "hive.missing_permissions"
      assert_includes findings.codes, "hive.invalid_mapping_role"
      assert_includes findings.codes, "hive.invalid_mapping_contract"
    end
  end

  def test_registry_contract_rejects_external_skills_raw_council_commands_and_old_hive_floor
    with_package do |package, _manifest, _workflow|
      workflow = managed_workflow
      workflow["stages"][0]["skill"] = "/outside"
      workflow["stages"][0]["reviewers"][0]["command"] = "unsafe"
      workflow["stages"][0]["council"]["revise"]["skill"] = "/outside"
      manifest = managed_manifest("hive_min_version" => "0.5.3")

      findings = validate_contract(package, workflow: workflow, manifest: manifest)
      assert_includes findings.codes, "hive.external_skill"
      assert_includes findings.codes, "hive.raw_council_command"
      assert_includes findings.codes, "hive.minimum_contract_version"
    end
  end

  def test_registry_contract_accepts_explicit_yolo_and_valid_slot_authorizations
    with_package do |package, _manifest, _workflow|
      workflow = managed_workflow
      workflow["stages"][0]["permissions"] = "yolo"
      manifest = managed_manifest(
        "x-hive" => {
          "tools" => [],
          "optional_inputs" => [
            {"name" => "SEO_API_TOKEN", "authorized_slots" => ["stages.draft", "stages.draft.reviewers.accuracy"]}
          ]
        }
      )

      findings = validate_contract(package, workflow: workflow, manifest: manifest)

      refute findings.errors?, findings.to_h.inspect
      permissions = HoneycombRegistry::Permissions.derive(workflow).permissions
      assert_equal "high", permissions.fetch("risk")
      assert_equal ["*"], permissions.fetch("secrets")
    end
  end

  def test_input_authorization_rejects_unknown_and_terminal_slots
    with_package do |package, _manifest, _workflow|
      %w[stages.missing stages.done].each do |slot|
        manifest = managed_manifest(
          "x-hive" => {
            "tools" => [],
            "optional_inputs" => [{"name" => "SEO_API_TOKEN", "authorized_slots" => [slot]}]
          }
        )

        findings = validate_contract(package, manifest: manifest)

        assert_includes findings.codes, slot == "stages.done" ? "hive.terminal_input_slot" : "hive.unknown_input_slot"
      end
    end
  end

  def test_tool_declarations_are_contained_hashed_and_exactly_executable
    with_package do |package, _manifest, _workflow|
      tools = File.join(package.path, "tools")
      FileUtils.mkdir_p(tools)
      tool = File.join(tools, "analyze.rb")
      File.write(tool, "#!/usr/bin/env ruby\nputs :ok\n")
      File.chmod(0o755, tool)
      inventory = package.inspect.files
      manifest = managed_manifest("x-hive" => {"tools" => [{"path" => "tools/analyze.rb"}], "optional_inputs" => []})

      findings = HoneycombRegistry::HiveCompatibility.validate_package_contract(
        package, manifest, workflow: managed_workflow, inventory: inventory,
        declared_files: inventory.to_h { |path| [path, "0" * 64] }
      )
      refute findings.errors?, findings.to_h.inspect

      findings = HoneycombRegistry::HiveCompatibility.validate_package_contract(
        package, manifest, workflow: managed_workflow, inventory: inventory, declared_files: {}
      )
      assert_includes findings.codes, "hive.unhashed_tool"

      File.chmod(0o644, tool)
      findings = HoneycombRegistry::HiveCompatibility.validate_package_contract(
        package, manifest, workflow: managed_workflow, inventory: inventory,
        declared_files: inventory.to_h { |path| [path, "0" * 64] }
      )
      assert_includes findings.codes, "hive.invalid_tool_mode"

      manifest["x-hive"]["tools"][0]["path"] = "../escape.rb"
      findings = validate_contract(package, manifest: manifest)
      assert_includes findings.codes, "hive.invalid_tool_path"
    end
  end

  def test_executable_payload_files_must_be_declared_as_tools
    with_package do |package, _manifest, _workflow|
      surprise = File.join(package.path, "instructions", "surprise.sh")
      File.write(surprise, "#!/bin/sh\necho surprise\n")
      File.chmod(0o755, surprise)

      findings = validate_contract(package)

      assert_includes findings.codes, "hive.undeclared_executable"
      assert findings.to_h.any? { |finding| finding["path"].end_with?("instructions/surprise.sh") }
    end
  end

  def test_only_exact_historical_versions_bypass_the_new_contract
    in_tmpdir do |root|
      legacy_path = File.join(root, "packages", "bench", "0.1.0")
      FileUtils.mkdir_p(File.dirname(legacy_path))
      FileUtils.cp_r(fixture_path("packages", "valid", "example", "1.0.0"), legacy_path)
      legacy = HoneycombRegistry::Package.new(legacy_path, root: root)
      findings = HoneycombRegistry::HiveCompatibility.validate_package_contract(
        legacy, {}, workflow: {"stages" => []}, inventory: legacy.inspect.files
      )
      refute findings.errors?, findings.to_h.inspect
      assert_includes findings.codes, "hive.legacy_package_contract"

      future_path = File.join(root, "packages", "bench", "0.1.1")
      FileUtils.mkdir_p(File.dirname(future_path))
      FileUtils.cp_r(fixture_path("packages", "valid", "example", "1.0.0"), future_path)
      future = HoneycombRegistry::Package.new(future_path, root: root)
      findings = HoneycombRegistry::HiveCompatibility.validate_package_contract(
        future, {}, workflow: {"stages" => []}, inventory: future.inspect.files
      )
      assert findings.errors?
      refute_includes findings.codes, "hive.legacy_package_contract"
      assert_includes findings.codes, "hive.missing_extension"
    end
  end
end
