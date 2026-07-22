# frozen_string_literal: true

require "stringio"
require "set"

module HoneycombRegistry
  module HiveCompatibility
    Runtime = Struct.new(:version, :parser, keyword_init: true)
    LEGACY_PACKAGE_CONTRACTS = Set[
      ["bench", "0.1.0"],
      ["docs-sync", "0.1.0"],
      ["task-inspect", "0.1.0"]
    ].freeze
    EXECUTABLE_STAGE_KINDS = %w[agent council].freeze
    MAPPING_ROLES = %w[planning development reviewer].freeze
    MAPPING_CONTRACT_PATTERN = /\A[a-z0-9][a-z0-9._-]{0,63}\z/
    IDENTITY_KEYS = %w[agent model effort].freeze
    MANAGED_HIVE_MIN_VERSION = SemVer.parse("0.6.0")

    module_function

    def validate_package_contract(package, manifest, workflow:, inventory:, declared_files: nil)
      findings = Findings.new
      if LEGACY_PACKAGE_CONTRACTS.include?([package.name, package.version])
        findings.add(package.repository_path("workflow.yml"), "hive.legacy_package_contract",
                     "historical immutable package predates the managed mapping contract", :info)
        return findings
      end

      begin
        declared_minimum = SemVer.parse(manifest.fetch("hive_min_version"))
        if declared_minimum < MANAGED_HIVE_MIN_VERSION
          findings.add(package.relative_manifest_path, "hive.minimum_contract_version",
                       "managed packages must require Hive #{MANAGED_HIVE_MIN_VERSION} or newer")
        end
      rescue KeyError, SemVer::Invalid
        # The schema validator owns malformed or missing SemVer diagnostics.
      end

      extension = manifest.is_a?(Hash) ? manifest["x-hive"] : nil
      unless extension.is_a?(Hash)
        findings.add(package.relative_manifest_path, "hive.missing_extension",
                     "new packages must declare the strict x-hive runtime extension")
        extension = {}
      end

      executable_slots, terminal_slots = validate_actors(workflow, package, findings)
      validate_hive_extension_semantics(
        package, extension, inventory, declared_files, executable_slots, terminal_slots, findings
      )
      findings
    end

    def check(package, manifest, workflow:, require_hive: false, loader: method(:load_runtime))
      findings = Findings.new
      runtime = loader.call
      unless runtime
        severity = require_hive ? :error : :warning
        findings.add(package.repository_path("workflow.yml"), "hive.missing",
                     require_hive ? "Hive is required for strict compatibility validation" :
                                    "Hive is not installed; descriptor compatibility was not checked",
                     severity)
        return findings
      end

      installed = SemVer.parse(runtime.version.to_s)
      required = SemVer.parse(manifest.fetch("hive_min_version"))
      if installed < required
        findings.add(package.repository_path("workflow.yml"), "hive.version_too_old",
                     "installed Hive #{installed} is older than declared minimum #{required}")
        return findings
      end
      unless runtime.parser.respond_to?(:parse_hash)
        findings.add(package.repository_path("workflow.yml"), "hive.parser_unavailable",
                     "installed Hive does not expose DescriptorParser.parse_hash")
        return findings
      end

      synthetic_path = File.join(package.path, "#{package.name}.yml")
      warnings = capture_stderr { runtime.parser.parse_hash(workflow, path: synthetic_path) }
      warnings.lines.map(&:strip).reject(&:empty?).each do |warning|
        findings.add(package.repository_path("workflow.yml"), "hive.parser_warning", warning, :warning)
      end
      findings.add(package.repository_path("workflow.yml"), "hive.compatible",
                   "descriptor parsed with Hive #{installed}", :info)
      findings
    rescue LoadError
      severity = require_hive ? :error : :warning
      findings.add(package.repository_path("workflow.yml"), "hive.missing",
                   require_hive ? "Hive is required for strict compatibility validation" :
                                  "Hive is not installed; descriptor compatibility was not checked",
                   severity)
    rescue SemVer::Invalid, KeyError => e
      findings.add(package.repository_path("workflow.yml"), "hive.invalid_version", e.message)
    rescue StandardError => e
      findings.add(package.repository_path("workflow.yml"), "hive.parser_rejected",
                   "Hive rejected the descriptor: #{e.message}")
    end

    def validate_actors(workflow, package, findings)
      executable = Set.new
      terminal = Set.new
      workflow_path = package.repository_path("workflow.yml")
      stages = workflow.is_a?(Hash) ? workflow["stages"] : nil
      return [executable, terminal] unless stages.is_a?(Array)

      stages.each_with_index do |stage, index|
        next unless stage.is_a?(Hash)

        stage_path = "#{workflow_path}.stages[#{index}]"
        stage_name = stage["name"]
        stage_slot = "stages.#{stage_name}" if stable_segment?(stage_name)
        if EXECUTABLE_STAGE_KINDS.include?(stage["kind"])
          executable << stage_slot if stage_slot
          validate_actor(stage, stage_path, allowed_roles: MAPPING_ROLES, findings: findings, nested: false)
        elsif stage_slot
          terminal << stage_slot
        end

        reviewers = stage["reviewers"]
        if reviewers.is_a?(Array)
          reviewers.each_with_index do |reviewer, reviewer_index|
            next unless reviewer.is_a?(Hash)

            reviewer_path = "#{stage_path}.reviewers[#{reviewer_index}]"
            reviewer_name = reviewer["name"]
            if stage_slot && stable_segment?(reviewer_name)
              executable << "#{stage_slot}.reviewers.#{reviewer_name}"
            end
            validate_actor(reviewer, reviewer_path, allowed_roles: ["reviewer"], findings: findings, nested: true)
          end
        end

        revise = stage.dig("council", "revise") if stage["council"].is_a?(Hash)
        if revise.is_a?(Hash)
          executable << "#{stage_slot}.revise" if stage_slot
          validate_actor(revise, "#{stage_path}.council.revise",
                         allowed_roles: %w[planning development], findings: findings, nested: true)
        end
      end
      [executable, terminal]
    end

    def validate_actor(actor, path, allowed_roles:, findings:, nested:)
      IDENTITY_KEYS.each do |key|
        next unless actor.key?(key)

        findings.add("#{path}.#{key}", "hive.embedded_identity",
                     "managed packages must not embed #{key}; installation owns execution identity")
      end
      if actor.key?("skill")
        findings.add("#{path}.skill", "hive.external_skill",
                     "managed actors must use package-local instruction or prompt content")
      end
      if nested && actor.key?("command")
        findings.add("#{path}.command", "hive.raw_council_command",
                     "managed council actors cannot execute raw commands")
      end

      role = actor["mapping_role"]
      unless allowed_roles.include?(role)
        findings.add("#{path}.mapping_role", "hive.invalid_mapping_role",
                     "mapping_role must be one of #{allowed_roles.join(', ')}")
      end
      contract = actor["mapping_contract"]
      unless contract.is_a?(String) && MAPPING_CONTRACT_PATTERN.match?(contract)
        findings.add("#{path}.mapping_contract", "hive.invalid_mapping_contract",
                     "mapping_contract must be a normalized lowercase revision token")
      end
      unless actor.key?("permissions")
        findings.add("#{path}.permissions", "hive.missing_permissions",
                     "every managed executable actor must declare exact permissions, including explicit yolo")
      end
    end

    def validate_hive_extension_semantics(package, extension, inventory, declared_files,
                                          executable_slots, terminal_slots, findings)
      validate_tool_semantics(package, extension["tools"], inventory, declared_files, findings)
      validate_prompt_asset_semantics(package, extension["prompt_assets"], inventory, declared_files, findings)
      inputs = extension["optional_inputs"]
      if inputs.is_a?(Array)
        inputs.each_with_index do |input, input_index|
          next unless input.is_a?(Hash) && input["authorized_slots"].is_a?(Array)

          input["authorized_slots"].each_with_index do |slot, slot_index|
            next unless slot.is_a?(String)
            next if executable_slots.include?(slot)

            path = "#{package.relative_manifest_path}.x-hive.optional_inputs[#{input_index}].authorized_slots[#{slot_index}]"
            if terminal_slots.include?(slot)
              findings.add(path, "hive.terminal_input_slot", "optional inputs cannot be authorized for terminal slots")
            else
              findings.add(path, "hive.unknown_input_slot", "optional input references an unknown executable slot")
            end
          end
        end
      end

      validate_mapping_recommendation_semantics(
        package, extension["mapping_recommendations"], executable_slots, terminal_slots, findings
      )
    end

    def validate_mapping_recommendation_semantics(package, recommendations, executable_slots, terminal_slots, findings)
      return unless recommendations.is_a?(Array)

      recommendations.each_with_index do |recommendation, index|
        next unless recommendation.is_a?(Hash)

        slot = recommendation["slot"]
        next unless slot.is_a?(String)
        next if executable_slots.include?(slot)

        path = "#{package.relative_manifest_path}.x-hive.mapping_recommendations[#{index}].slot"
        if terminal_slots.include?(slot)
          findings.add(path, "hive.terminal_mapping_recommendation_slot",
                       "mapping recommendations cannot name terminal slots")
        else
          findings.add(path, "hive.unknown_mapping_recommendation_slot",
                       "mapping recommendation references an unknown executable slot")
        end
      end
    end

    def validate_tool_semantics(package, tools, inventory, declared_files, findings)
      tools = [] unless tools.is_a?(Array)
      inventory = inventory.to_set
      declared_tool_paths = Set.new
      tools.each_with_index do |tool, index|
        next unless tool.is_a?(Hash)

        relative = tool["path"]
        path = "#{package.relative_manifest_path}.x-hive.tools[#{index}].path"
        unless Schema.valid_package_relative_path?(relative)
          findings.add(path, "hive.invalid_tool_path", "tool path must remain inside the package")
          next
        end
        repository_path = package.repository_path(relative)
        declared_tool_paths << repository_path
        unless inventory.include?(repository_path)
          findings.add(path, "hive.missing_tool", "tool path is not a regular package inventory file")
          next
        end
        if declared_files.is_a?(Hash) && !declared_files.key?(repository_path)
          findings.add(path, "hive.unhashed_tool", "tool path is not hash-covered by the manifest inventory")
        end
        begin
          mode = File.lstat(package.absolute_path(repository_path)).mode & 0o777
          if (mode & 0o100).zero?
            findings.add(path, "hive.invalid_tool_mode", "package tools must carry the trusted Git executable bit")
          end
        rescue SystemCallError, ArgumentError => e
          findings.add(path, "hive.unreadable_tool", e.message)
        end
      end

      inventory.each do |repository_path|
        next if declared_tool_paths.include?(repository_path)

        begin
          mode = File.lstat(package.absolute_path(repository_path)).mode
          next if (mode & 0o111).zero?

          findings.add(repository_path, "hive.undeclared_executable",
                       "executable package files must be declared in x-hive.tools")
        rescue SystemCallError, ArgumentError => e
          findings.add(repository_path, "hive.unreadable_tool", e.message)
        end
      end
    end

    def validate_prompt_asset_semantics(package, assets, inventory, declared_files, findings)
      assets = [] unless assets.is_a?(Array)
      inventory = inventory.to_set
      assets.each_with_index do |asset, index|
        next unless asset.is_a?(Hash)

        relative = asset["path"]
        path = "#{package.relative_manifest_path}.x-hive.prompt_assets[#{index}].path"
        unless Schema.valid_package_relative_path?(relative)
          findings.add(path, "hive.invalid_prompt_asset_path", "prompt asset path must remain inside the package")
          next
        end
        repository_path = package.repository_path(relative)
        unless inventory.include?(repository_path)
          findings.add(path, "hive.missing_prompt_asset", "prompt asset is not a regular package inventory file")
          next
        end
        if declared_files.is_a?(Hash) && !declared_files.key?(repository_path)
          findings.add(path, "hive.unhashed_prompt_asset", "prompt asset is not hash-covered by the manifest inventory")
        end
      end
    end

    def stable_segment?(value)
      value.is_a?(String) && /\A[a-z0-9][a-z0-9_-]*\z/.match?(value)
    end

    def load_runtime
      require "hive"
      require "hive/workflows/descriptor_parser"
      return nil unless defined?(Hive::Workflows::DescriptorParser)

      version = if defined?(Hive::VERSION)
                  Hive::VERSION
                elsif Gem.loaded_specs["hive-cli"]
                  Gem.loaded_specs.fetch("hive-cli").version.to_s
                end
      return nil unless version

      Runtime.new(version: version.to_s, parser: Hive::Workflows::DescriptorParser)
    end

    def capture_stderr
      previous = $stderr
      captured = StringIO.new
      $stderr = captured
      yield
      captured.string
    ensure
      $stderr = previous
    end
  end
end
