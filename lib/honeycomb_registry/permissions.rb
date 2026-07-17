# frozen_string_literal: true

require "pathname"
require "set"

module HoneycombRegistry
  module Permissions
    Result = Struct.new(:permissions, :findings, keyword_init: true)

    READ_TOOLS = %w[Glob Grep LS Read].freeze
    WRITE_TOOLS = %w[Edit MultiEdit NotebookEdit Write].freeze
    NETWORK_TOOLS = %w[WebFetch WebSearch].freeze
    SHELL_TOOLS = %w[Bash].freeze
    KNOWN_TOOLS = (READ_TOOLS + WRITE_TOOLS + NETWORK_TOOLS + SHELL_TOOLS).freeze
    TOOL_RULE_PATTERN = /\A(?<tool>[A-Za-z][A-Za-z0-9_.:*-]*)(?:\((?<specifier>[^(),\s\x00]+)\))?\z/
    UNSUPPORTED_FILE_RULES = {
      "Write" => "Edit", "MultiEdit" => "Edit", "NotebookEdit" => "Edit",
      "LS" => "Read", "Grep" => "Read", "Glob" => "Read"
    }.freeze
    ALLOWED_SCOPE_KEYS = %w[preset tools dirs bash].freeze
    RISK_ORDER = {"low" => 0, "moderate" => 1, "high" => 2}.freeze
    PROJECT_ROOT_DIR = "../../../.."

    module_function

    def derive(descriptor, path: "workflow.yml")
      findings = Findings.new
      union = empty_union
      recognized_paths = Set.new

      unless descriptor.is_a?(Hash) && descriptor["stages"].is_a?(Array)
        findings.add(path, "permissions.invalid_descriptor",
                     "workflow descriptor must contain a stages array")
        return Result.new(permissions: nil, findings: findings)
      end

      descriptor["stages"].each_with_index do |stage, index|
        stage_path = "#{path}.stages[#{index}]"
        unless stage.is_a?(Hash)
          findings.add(stage_path, "permissions.invalid_descriptor", "stage must be a mapping")
          next
        end

        if %w[agent council].include?(stage["kind"])
          process_holder(stage, stage_path, union, findings, recognized_paths)
        end
        process_reviewers(stage["reviewers"], "#{stage_path}.reviewers", union,
                          findings, recognized_paths) if stage.key?("reviewers")
        process_revise(stage["council"], "#{stage_path}.council", union,
                       findings, recognized_paths) if stage.key?("council")
      end

      scan_permission_constructs(descriptor, path, recognized_paths, findings)
      permissions = findings.errors? ? nil : finalize(union)
      Result.new(permissions: permissions, findings: findings)
    end

    def process_reviewers(reviewers, path, union, findings, recognized_paths)
      unless reviewers.is_a?(Array)
        findings.add(path, "permissions.invalid_descriptor", "reviewers must be an array")
        return
      end
      reviewers.each_with_index do |reviewer, index|
        reviewer_path = "#{path}[#{index}]"
        unless reviewer.is_a?(Hash)
          findings.add(reviewer_path, "permissions.invalid_descriptor", "reviewer must be a mapping")
          next
        end
        process_holder(reviewer, reviewer_path, union, findings, recognized_paths)
      end
    end

    def process_revise(council, path, union, findings, recognized_paths)
      return if council.nil?
      unless council.is_a?(Hash)
        findings.add(path, "permissions.invalid_descriptor", "council must be a mapping")
        return
      end
      return unless council.key?("revise")

      revise = council["revise"]
      revise_path = "#{path}.revise"
      unless revise.is_a?(Hash)
        findings.add(revise_path, "permissions.invalid_descriptor", "revise must be a mapping")
        return
      end
      process_holder(revise, revise_path, union, findings, recognized_paths)
    end

    def process_holder(holder, holder_path, union, findings, recognized_paths)
      permission_path = "#{holder_path}.permissions"
      recognized_paths << permission_path
      spec = holder.key?("permissions") ? holder["permissions"] : :absent
      contribution = normalize_scope(spec, permission_path, findings)
      return unless contribution

      merge_union(union, contribution)
      preset = contribution.fetch(:label)
      findings.add(permission_path, "permissions.source",
                   "#{holder_path} contributes #{preset} permissions", :info)
      if contribution.fetch(:unbounded)
        findings.add(permission_path, "permissions.unbounded",
                     "#{holder_path} requests unbounded access", :warning)
      end
    end

    def normalize_scope(spec, path, findings)
      return unbounded("implicit yolo default") if spec == :absent
      if spec.nil?
        findings.add(path, "permissions.invalid", "permissions must not be blank")
        return
      end

      normalized = case spec
                   when String
                     {"preset" => spec}
                   when Hash
                     unless spec.keys.all? { |key| key.is_a?(String) }
                       findings.add(path, "permissions.invalid", "permission keys must be strings")
                       return
                     end
                     spec
                   else
                     findings.add(path, "permissions.invalid",
                                  "permissions must be a preset string or mapping")
                     return
                   end

      preset = normalized["preset"]
      unless %w[yolo read-only scoped].include?(preset)
        findings.add("#{path}.preset", "permissions.invalid_preset",
                     "preset must be yolo, read-only, or scoped")
        return
      end

      allowed = preset == "scoped" ? ALLOWED_SCOPE_KEYS : %w[preset]
      unknown = normalized.keys - allowed
      unless unknown.empty?
        findings.add(path, "permissions.unknown_key",
                     "unsupported permission keys: #{unknown.sort.join(", ")}")
        return
      end

      case preset
      when "yolo" then unbounded("yolo")
      when "read-only" then bounded_read
      when "scoped" then normalize_scoped(normalized, path, findings)
      end
    end

    def normalize_scoped(spec, path, findings)
      if spec.key?("tools") && spec.key?("bash")
        findings.add(path, "permissions.invalid", "scoped tools and bash are mutually exclusive")
        return
      end
      unless spec.key?("tools") || spec.key?("bash")
        findings.add(path, "permissions.invalid", "scoped permissions require tools or bash")
        return
      end

      dirs = normalize_dirs(spec.fetch("dirs", []), "#{path}.dirs", findings)
      return unless dirs

      if spec.key?("bash")
        unless spec["bash"] == true || spec["bash"] == false
          findings.add("#{path}.bash", "permissions.invalid", "bash must be true or false")
          return
        end
        return spec["bash"] ? unbounded("scoped Bash") : bounded_read("scoped bash: false", dirs)
      end

      tools = spec["tools"]
      unless tools.is_a?(Array) && !tools.empty? && tools.all? { |tool| tool.is_a?(String) && !tool.empty? }
        findings.add("#{path}.tools", "permissions.invalid", "tools must be a non-empty string array")
        return
      end
      rules = normalize_tool_rules(tools, "#{path}.tools", findings)
      return unless rules
      return unbounded("scoped Bash tool") if rules.any? { |rule| rule.fetch(:tool) == "Bash" }

      contribution = {
        label: "scoped tools",
        risk: "low",
        capabilities: Set.new,
        network_hosts: Set.new,
        filesystem_read: Set.new,
        filesystem_write: Set.new,
        secrets: Set.new,
        unbounded: false
      }
      rules.each do |rule|
        tool = rule.fetch(:tool)
        specifier = rule[:specifier]
        if specifier && tool == "Read"
          contribution[:capabilities] << "filesystem-read"
          contribution[:filesystem_read] << specifier
        elsif specifier && tool == "Edit"
          contribution[:risk] = "moderate"
          contribution[:capabilities] << "filesystem-write"
          contribution[:filesystem_write] << specifier
        elsif READ_TOOLS.include?(tool)
          contribution[:capabilities] << "filesystem-read"
          contribution[:filesystem_read].merge(["task"] + dirs)
        elsif WRITE_TOOLS.include?(tool)
          contribution[:risk] = "moderate"
          contribution[:capabilities] << "filesystem-write"
          contribution[:filesystem_write].merge(["task"] + dirs)
        elsif NETWORK_TOOLS.include?(tool)
          contribution[:risk] = "high"
          contribution[:capabilities] << "network"
          contribution[:network_hosts] << "*"
          contribution[:unbounded] = true
        end
      end
      contribution
    end

    def normalize_tool_rules(tools, path, findings)
      rules = tools.each_with_index.filter_map do |rule, index|
        match = TOOL_RULE_PATTERN.match(rule)
        unless match
          findings.add("#{path}[#{index}]", "permissions.invalid_tool_rule",
                       "tool must be Tool or Tool(non-empty-specifier)")
          next
        end

        tool = match[:tool]
        unless KNOWN_TOOLS.include?(tool)
          findings.add("#{path}[#{index}]", "permissions.unknown_tool",
                       "unsupported permission-bearing tool: #{tool}")
          next
        end

        specifier = match[:specifier]
        if specifier && UNSUPPORTED_FILE_RULES.key?(tool)
          replacement = UNSUPPORTED_FILE_RULES.fetch(tool)
          findings.add("#{path}[#{index}]", "permissions.unsupported_file_rule",
                       "#{tool}(path) is not enforced by Hive; use #{replacement}(path)")
          next
        end

        if specifier && %w[Read Edit].include?(tool)
          specifier = normalize_scope_path(specifier)
          unless specifier
            findings.add("#{path}[#{index}]", "permissions.invalid_tool_path",
                         "file rule must be task-relative or use the exact ../../../../ project anchor")
            next
          end
        end
        {tool: tool, specifier: specifier}
      end
      return if findings.errors?

      rules
    end

    def normalize_dirs(dirs, path, findings)
      unless dirs.is_a?(Array)
        findings.add(path, "permissions.invalid_dir", "dirs must be an array")
        return
      end

      normalized = []
      dirs.each_with_index do |dir, index|
        unless dir.is_a?(String) && !dir.empty? && dir == dir.strip &&
               !dir.include?("\0") && !dir.include?("\\") && !Pathname.new(dir).absolute?
          findings.add("#{path}[#{index}]", "permissions.invalid_dir",
                       "dir must be a normalized relative path")
          next
        end
        projected = normalize_scope_path(dir)
        unless projected
          findings.add("#{path}[#{index}]", "permissions.invalid_dir",
                       "dir must be task-relative or use the exact ../../../../ project anchor")
          next
        end
        normalized << projected
      end
      return if findings.errors?

      normalized.uniq.sort
    end

    def normalize_scope_path(dir)
      return unless dir.is_a?(String) && !dir.empty? && dir == dir.strip
      return if dir.include?("\0") || dir.include?("\\") || Pathname.new(dir).absolute?
      return if dir.start_with?("~") || dir.match?(/\A[A-Za-z]:\//)

      if dir == PROJECT_ROOT_DIR
        return "repository"
      elsif dir.start_with?("#{PROJECT_ROOT_DIR}/")
        relative = dir.delete_prefix("#{PROJECT_ROOT_DIR}/")
        segments = relative.split("/")
        return if segments.empty? || segments.any? { |segment| segment.empty? || %w[. ..].include?(segment) }
        return unless Pathname.new(relative).cleanpath.to_s == relative

        return "repository/#{relative}"
      end

      segments = dir.split("/")
      return if segments.include?("..") || segments.any?(&:empty?)

      clean = Pathname.new(dir).cleanpath.to_s
      clean == "." ? "task" : "task/#{clean.sub(%r{\A\./}, "")}"
    end

    def bounded_read(label = "read-only", dirs = [])
      {
        label: label,
        risk: "low",
        capabilities: Set["filesystem-read"],
        network_hosts: Set.new,
        filesystem_read: Set.new(%w[repository task] + dirs),
        filesystem_write: Set.new,
        secrets: Set.new,
        unbounded: false
      }
    end

    def unbounded(label)
      {
        label: label,
        risk: "high",
        capabilities: Set.new(Schema::CAPABILITIES),
        network_hosts: Set["*"],
        filesystem_read: Set["*"],
        filesystem_write: Set["*"],
        secrets: Set["*"],
        unbounded: true
      }
    end

    def empty_union
      {
        risk: "low",
        capabilities: Set.new,
        network_hosts: Set.new,
        filesystem_read: Set.new,
        filesystem_write: Set.new,
        secrets: Set.new
      }
    end

    def merge_union(union, contribution)
      if RISK_ORDER.fetch(contribution[:risk]) > RISK_ORDER.fetch(union[:risk])
        union[:risk] = contribution[:risk]
      end
      %i[capabilities network_hosts filesystem_read filesystem_write secrets].each do |key|
        union[key].merge(contribution.fetch(key))
      end
    end

    def finalize(union)
      {
        "risk" => union[:risk],
        "capabilities" => canonical_set(union[:capabilities]),
        "network_hosts" => canonical_set(union[:network_hosts]),
        "filesystem_read" => canonical_set(union[:filesystem_read]),
        "filesystem_write" => canonical_set(union[:filesystem_write]),
        "secrets" => canonical_set(union[:secrets])
      }
    end

    def canonical_set(values)
      values.include?("*") ? ["*"] : values.to_a.sort
    end

    def scan_permission_constructs(value, path, recognized_paths, findings)
      case value
      when Hash
        value.each do |key, child|
          next unless key.is_a?(String)

          child_path = "#{path}.#{key}"
          if key.downcase.include?("permission") && !recognized_paths.include?(child_path)
            findings.add(child_path, "permissions.unknown_construct",
                         "unsupported permission-bearing construct #{key.inspect}")
          end
          scan_permission_constructs(child, child_path, recognized_paths, findings)
        end
      when Array
        value.each_with_index do |child, index|
          scan_permission_constructs(child, "#{path}[#{index}]", recognized_paths, findings)
        end
      end
    end
  end
end
