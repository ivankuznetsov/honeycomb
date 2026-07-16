# frozen_string_literal: true

require "pathname"
require "set"

module HoneycombRegistry
  class Package
    Discovery = Struct.new(:packages, :findings, keyword_init: true)
    Inspection = Struct.new(:files, :findings, keyword_init: true)

    attr_reader :path, :root, :name, :version

    def self.discover(root)
      root = File.expand_path(root)
      packages_root = File.join(root, "packages")
      findings = Findings.new
      packages = []
      return Discovery.new(packages: packages, findings: findings) unless File.exist?(packages_root)

      unless File.directory?(packages_root) && !File.symlink?(packages_root)
        findings.add(relative(root, packages_root), "package.invalid_tree",
                     "packages must be a real directory")
        return Discovery.new(packages: packages, findings: findings)
      end

      Dir.children(packages_root).sort.each do |name|
        next if name == ".gitkeep"

        name_path = File.join(packages_root, name)
        unless File.directory?(name_path) && !File.symlink?(name_path)
          findings.add(relative(root, name_path), "package.invalid_tree",
                       "package name entries must be real directories")
          next
        end
        unless Schema::NAME_PATTERN.match?(name)
          findings.add(relative(root, name_path), "package.invalid_name",
                       "package directory name must match #{Schema::NAME_PATTERN.inspect}")
          next
        end

        Dir.children(name_path).sort.each do |version|
          version_path = File.join(name_path, version)
          unless File.directory?(version_path) && !File.symlink?(version_path)
            findings.add(relative(root, version_path), "package.invalid_tree",
                         "version entries must be real directories")
            next
          end
          begin
            SemVer.parse(version)
          rescue SemVer::Invalid => e
            findings.add(relative(root, version_path), "package.invalid_version", e.message)
            next
          end
          packages << new(version_path, root: root)
        end
      end
      Discovery.new(packages: packages.sort_by { |package| [package.name, SemVer.parse(package.version)] },
                    findings: findings)
    rescue SystemCallError => e
      findings.add("packages", "package.unreadable", e.message)
      Discovery.new(packages: packages, findings: findings)
    end

    def self.relative(root, path)
      Pathname.new(path).relative_path_from(Pathname.new(root)).to_s.tr(File::SEPARATOR, "/")
    rescue ArgumentError
      path.to_s
    end

    def initialize(path, root:)
      @root = File.expand_path(root)
      @path = File.expand_path(path, @root)
      @name = File.basename(File.dirname(@path))
      @version = File.basename(@path)
    end

    def manifest_path
      File.join(path, "manifest.yml")
    end

    def relative_manifest_path
      repository_path("manifest.yml")
    end

    def repository_path(relative)
      "packages/#{name}/#{version}/#{relative}".tr(File::SEPARATOR, "/")
    end

    def absolute_path(repository_relative)
      candidate = File.expand_path(repository_relative, root)
      prefix = path + File::SEPARATOR
      return candidate if candidate.start_with?(prefix)

      raise ArgumentError, "path escapes package: #{repository_relative.inspect}"
    end

    def inspect
      findings = Findings.new
      return Inspection.new(files: [], findings: findings) unless validate_location(findings)

      required = %w[workflow.yml README.md manifest.yml]
      required.each do |relative|
        required_path = File.join(path, relative)
        unless regular_without_symlink?(required_path)
          findings.add(repository_path(relative), "package.missing_required",
                       "required package file #{relative} must be a regular file")
        end
      end
      instructions = File.join(path, "instructions")
      unless File.directory?(instructions) && !File.symlink?(instructions)
        findings.add(repository_path("instructions"), "package.missing_required",
                     "instructions must be a real directory")
      end

      files = []
      normalized = {}
      walk(path, "", files, normalized, findings)
      instruction_prefix = repository_path("instructions/")
      unless files.any? { |file| file.start_with?(instruction_prefix) }
        findings.add(repository_path("instructions"), "package.empty_instructions",
                     "instructions must contain at least one regular file")
      end
      Inspection.new(files: files.sort, findings: findings)
    rescue SystemCallError => e
      findings.add(relative_path, "package.unreadable", e.message)
      Inspection.new(files: [], findings: findings)
    end

    def relative_path
      self.class.relative(root, path)
    end

    def validate_instruction_references(workflow, workflow_path: repository_path("workflow.yml"))
      findings = Findings.new
      return findings unless workflow.is_a?(Hash) && workflow["stages"].is_a?(Array)

      workflow["stages"].each_with_index do |stage, index|
        next unless stage.is_a?(Hash)

        stage_path = "#{workflow_path}.stages[#{index}]"
        validate_instruction(stage["instruction"], "#{stage_path}.instruction", findings) if stage.key?("instruction")
        if stage["reviewers"].is_a?(Array)
          stage["reviewers"].each_with_index do |reviewer, reviewer_index|
            next unless reviewer.is_a?(Hash) && reviewer.key?("instruction")

            validate_instruction(reviewer["instruction"],
                                 "#{stage_path}.reviewers[#{reviewer_index}].instruction", findings)
          end
        end
        revise = stage.dig("council", "revise") if stage["council"].is_a?(Hash)
        if revise.is_a?(Hash) && revise.key?("instruction")
          validate_instruction(revise["instruction"], "#{stage_path}.council.revise.instruction", findings)
        end
      end
      findings
    end

    private

    def validate_location(findings)
      packages_root = File.join(root, "packages")
      relative = self.class.relative(root, path)
      segments = relative.split("/")
      unless segments.length == 3 && segments.first == "packages" &&
             segments[1] == name && segments[2] == version &&
             path.start_with?(packages_root + File::SEPARATOR)
        findings.add(relative, "package.outside_root",
                     "package path must be packages/<name>/<semver> under the repository root")
        return false
      end
      unless Schema::NAME_PATTERN.match?(name)
        findings.add(relative, "package.invalid_name", "directory name is not a valid honeycomb name")
      end
      begin
        SemVer.parse(version)
      rescue SemVer::Invalid => e
        findings.add(relative, "package.invalid_version", e.message)
      end

      [packages_root, File.join(packages_root, name), path].each do |component|
        stat = File.lstat(component)
        if stat.symlink? || !stat.directory?
          findings.add(self.class.relative(root, component), "package.symlink",
                       "package path components must be real directories")
        end
      rescue Errno::ENOENT
        findings.add(self.class.relative(root, component), "package.missing",
                     "package path does not exist")
      end
      !findings.errors?
    end

    def walk(directory, relative, files, normalized, findings)
      Dir.children(directory).sort.each do |entry|
        child_relative = relative.empty? ? entry : "#{relative}/#{entry}"
        child_path = File.join(directory, entry)
        stat = File.lstat(child_path)
        if stat.symlink?
          findings.add(repository_path(child_relative), "package.symlink",
                       "symlinks are not allowed in package content")
        elsif stat.directory?
          walk(child_path, child_relative, files, normalized, findings)
        elsif stat.file?
          validate_file_name(child_relative, normalized, findings)
          next if child_relative == "manifest.yml"

          if File.readable?(child_path)
            files << repository_path(child_relative)
          else
            findings.add(repository_path(child_relative), "package.unreadable",
                         "package file is not readable")
          end
        else
          findings.add(repository_path(child_relative), "package.special_file",
                       "special files are not allowed in package content")
        end
      end
    end

    def validate_file_name(relative, normalized, findings)
      invalid = relative.include?("\\") || relative.start_with?("/") ||
                relative.split("/").any? { |segment| segment.empty? || segment == "." || segment == ".." }
      if invalid
        findings.add(repository_path(relative), "package.ambiguous_path",
                     "package paths must use normalized forward-slash relative names")
      end
      canonical = relative.unicode_normalize(:nfc)
      if normalized.key?(canonical) && normalized[canonical] != relative
        findings.add(repository_path(relative), "package.duplicate_path",
                     "path normalizes to the same name as #{normalized[canonical].inspect}")
      end
      normalized[canonical] = relative
    end

    def regular_without_symlink?(candidate)
      stat = File.lstat(candidate)
      stat.file? && !stat.symlink?
    rescue Errno::ENOENT
      false
    end

    def validate_instruction(value, finding_path, findings)
      unless value.is_a?(String) && !value.empty? && value == value.strip &&
             !value.include?("\\") && !value.include?("\0") && !Pathname.new(value).absolute?
        findings.add(finding_path, "package.invalid_instruction_path",
                     "instruction must be a normalized relative path under instructions/")
        return
      end
      segments = value.split("/")
      clean = Pathname.new(value).cleanpath.to_s
      unless segments.none? { |segment| segment.empty? || segment == "." || segment == ".." } &&
             clean == value && value.start_with?("instructions/")
        findings.add(finding_path, "package.invalid_instruction_path",
                     "instruction must stay under the package instructions/ directory")
        return
      end
      candidate = File.join(path, value)
      unless regular_without_symlink?(candidate)
        findings.add(finding_path, "package.invalid_instruction_path",
                     "instruction must reference a regular package file")
      end
    end
  end
end
