# frozen_string_literal: true

require "digest"
require "optparse"

module HoneycombRegistry
  module Manifest
    Result = Struct.new(:document, :bytes, :findings, keyword_init: true)

    module_function

    def build(package)
      findings = Findings.new
      inspection = package.inspect
      findings.concat(inspection.findings)
      return Result.new(document: nil, bytes: nil, findings: findings) if findings.errors?

      metadata = load_yaml(package.manifest_path, package.relative_manifest_path, findings)
      return Result.new(document: nil, bytes: nil, findings: findings) unless metadata

      findings.concat(Schema.validate_metadata(metadata, path: package.relative_manifest_path))
      if metadata["name"] != package.name || metadata["version"] != package.version
        findings.add(package.relative_manifest_path, "manifest.identity",
                     "manifest name/version must match #{package.name}/#{package.version}")
      end

      workflow_path = File.join(package.path, "workflow.yml")
      workflow = load_yaml(workflow_path, package.repository_path("workflow.yml"), findings)
      if workflow
        findings.concat(package.validate_instruction_references(workflow))
        permission_result = Permissions.derive(workflow, path: package.repository_path("workflow.yml"))
        findings.concat(permission_result.findings)
        findings.concat(HiveCompatibility.validate_package_contract(
          package, metadata, workflow: workflow, inventory: inspection.files
        ))
      end
      return Result.new(document: nil, bytes: nil, findings: findings) if findings.errors?

      files = hash_files(package, inspection.files, findings)
      return Result.new(document: nil, bytes: nil, findings: findings) if findings.errors?

      document = project(metadata, permission_result.permissions, files)
      release_input = document.reject { |key, _value| key == "release_sha256" }
      document["release_sha256"] = Digest::SHA256.hexdigest(
        CanonicalYAML.dump_manifest(release_input, include_release: false)
      )
      document = order_document(document)
      findings.concat(Schema.validate_manifest(document, path: package.relative_manifest_path))
      return Result.new(document: nil, bytes: nil, findings: findings) if findings.errors?

      Result.new(document: document, bytes: CanonicalYAML.dump_manifest(document), findings: findings)
    rescue SystemCallError, IOError => e
      findings.add(package.relative_path, "manifest.io", e.message)
      Result.new(document: nil, bytes: nil, findings: findings)
    rescue ArgumentError => e
      findings.add(package.relative_path, "manifest.serialization", e.message)
      Result.new(document: nil, bytes: nil, findings: findings)
    end

    def generate(package)
      result = build(package)
      AtomicWrite.replace(package.manifest_path, result.bytes) unless result.findings.errors?
      result
    rescue SystemCallError, IOError => e
      result.findings.add(package.relative_manifest_path, "manifest.write", e.message)
      result
    end

    def check(package)
      existing = File.binread(package.manifest_path)
      result = build(package)
      if !result.findings.errors? && existing != result.bytes
        result.findings.add(package.relative_manifest_path, "manifest.drift",
                            "manifest is not the current canonical generated output")
      end
      result
    rescue Errno::ENOENT, Errno::EACCES => e
      findings = Findings.new.add(package.relative_manifest_path, "manifest.unreadable", e.message)
      Result.new(document: nil, bytes: nil, findings: findings)
    end

    def load_yaml(file_path, finding_path, findings)
      SafeYAML.load(File.binread(file_path), path: finding_path)
    rescue SafeYAML::Invalid => e
      findings.concat([e.finding])
      nil
    rescue Errno::ENOENT, Errno::EACCES => e
      findings.add(finding_path, "manifest.unreadable", e.message)
      nil
    end

    def hash_files(package, files, findings)
      files.sort.each_with_object({}) do |repository_path, hashes|
        absolute = package.absolute_path(repository_path)
        stat = File.lstat(absolute)
        unless stat.file? && !stat.symlink?
          findings.add(repository_path, "manifest.unsafe_file",
                       "file changed type during hashing")
          next
        end
        hashes[repository_path] = Digest::SHA256.file(absolute).hexdigest
      rescue SystemCallError, IOError => e
        findings.add(repository_path, "manifest.hash_read", e.message)
      end
    end

    def project(metadata, permissions, files)
      document = {}
      Schema::METADATA_KEYS.each { |key| document[key] = metadata[key] }
      document["permissions"] = permissions
      document["files"] = files.sort.to_h
      metadata.keys.grep(Schema::EXTENSION_PATTERN).sort.each do |key|
        document[key] = metadata[key]
      end
      document
    end

    def order_document(document)
      Schema::CORE_KEYS.each_with_object({}) do |key, ordered|
        ordered[key] = document[key]
      end.tap do |ordered|
        document.keys.grep(Schema::EXTENSION_PATTERN).sort.each { |key| ordered[key] = document[key] }
      end
    end
  end

  module ManifestCLI
    module_function

    def run(argv, out: $stdout, err: $stderr, default_root: nil)
      options = {check: false, all: false, root: default_root}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: honeycomb-manifest [--check] (--all | PACKAGE_PATH)"
        opts.on("--check", "Compare canonical bytes without writing") { options[:check] = true }
        opts.on("--all", "Process every package under packages/") { options[:all] = true }
        opts.on("--root PATH", "Repository root") { |value| options[:root] = value }
        opts.on("-h", "--help", "Show help") do
          out.puts opts
          return 0
        end
      end
      arguments = parser.parse(argv)
      root = File.expand_path(options[:root] || Dir.pwd)
      unless File.directory?(root) && (File.exist?(File.join(root, ".git")) || File.directory?(File.join(root, "packages")))
        raise InvocationError, "repository root is not recognizable: #{root}"
      end
      if options[:all]
        raise InvocationError, "--all cannot be combined with a package path" unless arguments.empty?
      elsif arguments.length != 1
        raise InvocationError, "provide exactly one package path or --all"
      end

      findings = Findings.new
      packages = if options[:all]
                   discovery = Package.discover(root)
                   findings.concat(discovery.findings)
                   discovery.packages
                 else
                   [Package.new(arguments.first, root: root)]
                 end

      results = if findings.errors?
                  []
                elsif options[:check]
                  packages.map { |package| Manifest.check(package) }
                else
                  packages.map { |package| Manifest.build(package) }
                end
      results.each { |result| findings.concat(result.findings) }
      if !options[:check] && !findings.errors?
        packages.zip(results).each do |package, result|
          AtomicWrite.replace(package.manifest_path, result.bytes)
        end
      end
      print_findings(findings, out)
      findings.errors? ? 1 : 0
    rescue OptionParser::ParseError, InvocationError => e
      err.puts "honeycomb-manifest: #{e.message}"
      2
    rescue StandardError => e
      err.puts "honeycomb-manifest: internal failure: #{e.class}: #{e.message}"
      2
    end

    def print_findings(findings, output)
      findings.each do |finding|
        output.puts "#{finding.severity.upcase} #{finding.path} #{finding.code}: #{finding.message}"
      end
    end
  end
end
