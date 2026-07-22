# frozen_string_literal: true

require_relative "test_helper"
require "digest"

MAPPING_RECOMMENDATION_HIVE_REVISION = "57b52dca65c2b037f9bf09007cf523ff7859d855"
mapping_recommendation_hive_source = ENV["HONEYCOMB_HIVE_SOURCE"].to_s
MAPPING_RECOMMENDATION_HIVE_PRECHECK_ERROR = begin
  unless mapping_recommendation_hive_source.empty?
    if !File.directory?(File.join(mapping_recommendation_hive_source, "lib"))
      "HONEYCOMB_HIVE_SOURCE does not contain Hive lib/"
    else
      head, head_error, head_status = Open3.capture3(
        "git", "-C", mapping_recommendation_hive_source, "rev-parse", "HEAD"
      )
      dirty, dirty_error, dirty_status = Open3.capture3(
        "git", "-C", mapping_recommendation_hive_source, "status", "--porcelain=v1", "--untracked-files=all"
      )
      flags, flags_error, flags_status = Open3.capture3(
        "git", "-C", mapping_recommendation_hive_source, "ls-files", "-v", "-f", "-z"
      )
      hidden_flag = flags.split("\0").find { |entry| !entry.empty? && entry.getbyte(0) != "H".ord }
      if !head_status.success?
        "cannot read Hive revision: #{head_error.strip}"
      elsif head.strip != MAPPING_RECOMMENDATION_HIVE_REVISION
        "Hive revision #{head.strip.inspect} is not #{MAPPING_RECOMMENDATION_HIVE_REVISION}"
      elsif !dirty_status.success?
        "cannot inspect Hive checkout: #{dirty_error.strip}"
      elsif !flags_status.success?
        "cannot inspect Hive index flags: #{flags_error.strip}"
      elsif hidden_flag
        "Hive checkout must not use non-default index flags; found #{hidden_flag.byteslice(0, 1).inspect}"
      elsif !dirty.empty?
        "Hive checkout must be clean; status is #{dirty.lines.first.to_s.strip.inspect}"
      end
    end
  end
end

$LOAD_PATH.unshift(File.join(mapping_recommendation_hive_source, "lib")) if MAPPING_RECOMMENDATION_HIVE_PRECHECK_ERROR.nil? && !mapping_recommendation_hive_source.empty?
MAPPING_RECOMMENDATION_HIVE_LOAD_ERROR = begin
  unless mapping_recommendation_hive_source.empty? || MAPPING_RECOMMENDATION_HIVE_PRECHECK_ERROR
    require "hive"
    require "hive/workflow_package/validator"
  end
  nil
rescue LoadError => e
  e
end

class HiveCompatibilityTest < Minitest::Test
  Runtime = HoneycombRegistry::HiveCompatibility::Runtime
  RECOMMENDATION_PARITY_CASES = {
    "absent" => {present: false, recommendations: nil, valid: true},
    "explicit empty" => {recommendations: [], valid: true},
    "canonical" => {
      recommendations: [
        {"slot" => "stages.review", "effort" => "medium"},
        {"slot" => "stages.review.reviewers.accuracy"},
        {"slot" => "stages.review.revise", "effort" => "high"},
        {"slot" => "stages.work", "effort" => "medium"}
      ],
      valid: true
    },
    "invalid effort" => {recommendations: [{"slot" => "stages.work", "effort" => "turbo"}], valid: false},
    "embedded agent" => {recommendations: [{"slot" => "stages.work", "agent" => "codex"}], valid: false},
    "embedded model" => {recommendations: [{"slot" => "stages.work", "model" => "gpt"}], valid: false},
    "unknown field" => {recommendations: [{"slot" => "stages.work", "unknown" => true}], valid: false},
    "non-array" => {recommendations: {"slot" => "stages.work"}, valid: false},
    "non-map entry" => {recommendations: ["stages.work"], valid: false},
    "missing slot" => {recommendations: [{"effort" => "medium"}], valid: false},
    "non-string slot" => {recommendations: [{"slot" => 1}], valid: false},
    "non-string effort" => {recommendations: [{"slot" => "stages.work", "effort" => 1}], valid: false},
    "null value" => {recommendations: nil, valid: false},
    "duplicate" => {
      recommendations: [{"slot" => "stages.work"}, {"slot" => "stages.work"}], valid: false
    },
    "unsorted" => {
      recommendations: [{"slot" => "stages.work"}, {"slot" => "stages.review"}], valid: false
    },
    "invalid syntax" => {recommendations: [{"slot" => "draft"}], valid: false},
    "unknown slot" => {recommendations: [{"slot" => "stages.missing"}], valid: false},
    "terminal slot" => {recommendations: [{"slot" => "stages.inbox"}], valid: false}
  }.freeze

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

  def test_mapping_recommendations_accept_only_executable_slots
    with_package do |package, _manifest, _workflow|
      manifest = managed_manifest(
        "x-hive" => {
          "mapping_recommendations" => [
            {"slot" => "stages.draft", "effort" => "medium"},
            {"slot" => "stages.draft.reviewers.accuracy"},
            {"slot" => "stages.draft.revise", "effort" => "high"}
          ],
          "tools" => [],
          "optional_inputs" => []
        }
      )

      findings = validate_contract(package, manifest: manifest)

      refute findings.errors?, findings.to_h.inspect
    end
  end

  def test_mapping_recommendations_reject_unknown_and_terminal_slots
    with_package do |package, _manifest, _workflow|
      {
        "stages.missing" => "hive.unknown_mapping_recommendation_slot",
        "stages.done" => "hive.terminal_mapping_recommendation_slot"
      }.each do |slot, expected_code|
        manifest = managed_manifest(
          "x-hive" => {
            "mapping_recommendations" => [{"slot" => slot, "effort" => "medium"}],
            "tools" => [],
            "optional_inputs" => []
          }
        )

        findings = validate_contract(package, manifest: manifest)

        assert_includes findings.codes, expected_code, [slot, findings.to_h]
      end
    end
  end

  def test_mapping_recommendation_acceptance_matches_pinned_hive_validator
    skip "set HONEYCOMB_HIVE_SOURCE to the pinned Hive checkout" if ENV["HONEYCOMB_HIVE_SOURCE"].to_s.empty?
    assert_nil MAPPING_RECOMMENDATION_HIVE_PRECHECK_ERROR, MAPPING_RECOMMENDATION_HIVE_PRECHECK_ERROR
    assert_nil MAPPING_RECOMMENDATION_HIVE_LOAD_ERROR,
               "pinned Hive could not be loaded: #{MAPPING_RECOMMENDATION_HIVE_LOAD_ERROR&.message}"

    RECOMMENDATION_PARITY_CASES.each do |name, fixture|
      with_package do |package, _manifest, _workflow|
        File.binwrite(File.join(package.path, "workflow.yml"), HoneycombRegistry::CanonicalYAML.dump(parity_workflow))
        result = HoneycombRegistry::Manifest.generate(package)
        refute result.findings.errors?, [name, result.findings.to_h].inspect
        write_mapping_recommendations(
          package, fixture.fetch(:recommendations), present: fixture.fetch(:present, true)
        )

        honeycomb_findings = validate_without_hive(package)
        hive_result = Hive::WorkflowPackage::Validator.validate(
          package.path, expected_name: package.name, managed: true
        )

        expected = fixture.fetch(:valid)
        assert_equal expected, !honeycomb_findings.errors?, [name, honeycomb_findings.to_h].inspect
        assert_equal expected, hive_result.valid?, [name, hive_result.diagnostics.map(&:to_h)].inspect
        assert_equal hive_result.valid?, !honeycomb_findings.errors?, [
          name, honeycomb_findings.to_h, hive_result.diagnostics.map(&:to_h)
        ].inspect
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

  private

  def validate_without_hive(package)
    HoneycombRegistry::Validator.validate(package, hive_loader: -> { nil })
  end

  def parity_workflow
    {
      "id" => "example",
      "stages" => [
        {"name" => "inbox", "kind" => "terminal", "state_file" => "brief.md"},
        {
          "name" => "work", "kind" => "agent", "state_file" => "work.md",
          "instruction" => "instructions/build.md", "mapping_role" => "development",
          "mapping_contract" => "v1", "permissions" => "read-only"
        },
        {
          "name" => "review", "kind" => "council", "state_file" => "review.md",
          "input" => "work.md", "mapping_role" => "development",
          "mapping_contract" => "v1", "permissions" => "read-only",
          "council" => {
            "quorum" => 1, "max_rounds" => 2, "exit_rule" => "consensus",
            "triage_output" => "reviews/triage.md",
            "revise" => {
              "instruction" => "instructions/build.md", "mapping_role" => "development",
              "mapping_contract" => "v1", "permissions" => "read-only"
            }
          },
          "reviewers" => [
            {
              "name" => "accuracy", "prompt" => "Review the work for accuracy.",
              "output_basename" => "accuracy", "mapping_role" => "reviewer",
              "mapping_contract" => "v1", "permissions" => "read-only"
            }
          ]
        }
      ]
    }
  end

  def write_mapping_recommendations(package, recommendations, present:)
    manifest = HoneycombRegistry::SafeYAML.load_file(package.manifest_path)
    extension = manifest.fetch("x-hive")
    if present
      extension["mapping_recommendations"] = recommendations
    else
      extension.delete("mapping_recommendations")
    end
    release_input = manifest.reject { |key, _value| key == "release_sha256" }
    manifest["release_sha256"] = Digest::SHA256.hexdigest(
      HoneycombRegistry::CanonicalYAML.dump_manifest(release_input, include_release: false)
    )
    File.binwrite(package.manifest_path, HoneycombRegistry::CanonicalYAML.dump_manifest(manifest))
  end
end
