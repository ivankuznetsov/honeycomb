# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "set"

module HoneycombRegistry
  module Validator
    module_function

    def validate(package, require_hive: false, hive_loader: HiveCompatibility.method(:load_runtime))
      findings = Findings.new
      inspection = package.inspect
      findings.concat(inspection.findings)

      manifest = load_yaml(package.manifest_path, package.relative_manifest_path, findings)
      return findings unless manifest.is_a?(Hash)

      schema_findings = Schema.validate_manifest(manifest, path: package.relative_manifest_path)
      findings.concat(schema_findings)
      if manifest["name"] != package.name || manifest["version"] != package.version
        findings.add(package.relative_manifest_path, "manifest.identity",
                     "manifest name/version must match #{package.name}/#{package.version}")
      end

      validate_file_integrity(package, inspection.files, manifest["files"], findings)

      workflow_path = File.join(package.path, "workflow.yml")
      workflow = load_yaml(workflow_path, package.repository_path("workflow.yml"), findings)
      if workflow
        findings.concat(package.validate_instruction_references(workflow))
        permission_result = Permissions.derive(workflow, path: package.repository_path("workflow.yml"))
        findings.concat(permission_result.findings)
        findings.concat(HiveCompatibility.validate_package_contract(
          package, manifest, workflow: workflow, inventory: inspection.files,
          declared_files: manifest["files"]
        ))
        if permission_result.permissions && manifest["permissions"] != permission_result.permissions
          findings.add("#{package.relative_manifest_path}.permissions", "permissions.drift",
                       "manifest permissions do not match workflow-derived permissions")
        end
      end

      validate_release_and_canonical_bytes(package, manifest, findings) unless schema_findings.errors?
      unless findings.errors? || !workflow
        findings.concat(HiveCompatibility.check(
          package, manifest, workflow: workflow, require_hive: require_hive, loader: hive_loader
        ))
      end
      findings
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

    def validate_file_integrity(package, actual_files, declared_files, findings)
      return unless declared_files.is_a?(Hash)

      actual = actual_files.to_set
      declared = declared_files.keys.select { |key| key.is_a?(String) }.to_set
      (actual - declared).sort.each do |path|
        findings.add(path, "integrity.unrecorded_file", "package file is not recorded in manifest")
      end
      (declared - actual).sort.each do |path|
        findings.add(path, "integrity.missing_file", "manifest records a file that is missing from package")
      end
      (actual & declared).sort.each do |path|
        absolute = package.absolute_path(path)
        stat = File.lstat(absolute)
        unless stat.file? && !stat.symlink?
          findings.add(path, "integrity.unsafe_file", "recorded path is not a regular package file")
          next
        end
        actual_digest = Digest::SHA256.file(absolute).hexdigest
        next if declared_files[path] == actual_digest

        findings.add(path, "integrity.digest_mismatch", "SHA-256 does not match manifest")
      rescue SystemCallError, IOError, ArgumentError => e
        findings.add(path, "integrity.unreadable", e.message)
      end
    end

    def validate_release_and_canonical_bytes(package, manifest, findings)
      projection = manifest.reject { |key, _value| key == "release_sha256" }
      expected_release = Digest::SHA256.hexdigest(
        CanonicalYAML.dump_manifest(projection, include_release: false)
      )
      unless manifest["release_sha256"] == expected_release
        findings.add("#{package.relative_manifest_path}.release_sha256",
                     "integrity.release_sha256",
                     "release fingerprint does not match canonical manifest content")
      end
      expected_bytes = CanonicalYAML.dump_manifest(manifest)
      actual_bytes = File.binread(package.manifest_path)
      unless actual_bytes == expected_bytes
        findings.add(package.relative_manifest_path, "manifest.noncanonical",
                     "manifest bytes are not canonical generated YAML")
      end
    rescue SystemCallError, IOError, ArgumentError => e
      findings.add(package.relative_manifest_path, "manifest.canonicalization", e.message)
    end
  end

  module ValidatorCLI
    module_function

    def run(argv, out: $stdout, err: $stderr, default_root: nil)
      options = {all: false, json: false, require_hive: false, root: default_root, help: false}
      parser = option_parser(options, out)
      arguments = parser.parse(argv)
      return 0 if options[:help]
      root = File.expand_path(options[:root] || Dir.pwd)
      verify_root!(root)
      packages, discovery_findings = resolve_packages(root, arguments, options)
      findings = Findings.new.concat(discovery_findings)
      unless findings.errors?
        packages.each do |package|
          findings.concat(Validator.validate(package, require_hive: options[:require_hive]))
        end
      end
      print_findings(findings, options[:json], out)
      findings.errors? ? 1 : 0
    rescue OptionParser::ParseError, InvocationError => e
      terminal_failure(e, "invocation.error", options && options[:json], out, err)
    rescue StandardError => e
      terminal_failure(e, "internal.error", options && options[:json], out, err, internal: true)
    end

    def option_parser(options, out)
      OptionParser.new do |opts|
        opts.banner = "Usage: honeycomb-validate [--json] [--require-hive] (--all | PACKAGE_PATH)"
        opts.on("--all", "Validate every package under packages/") { options[:all] = true }
        opts.on("--json", "Emit a stable JSON finding array") { options[:json] = true }
        opts.on("--require-hive", "Require compatible Hive parser validation") { options[:require_hive] = true }
        opts.on("--root PATH", "Repository root") { |value| options[:root] = value }
        opts.on("-h", "--help", "Show help") do
          out.puts opts
          options[:help] = true
        end
      end
    end

    def resolve_packages(root, arguments, options)
      findings = Findings.new
      if options[:all]
        raise InvocationError, "--all cannot be combined with a package path" unless arguments.empty?

        discovery = Package.discover(root)
        return [discovery.packages, discovery.findings]
      end
      raise InvocationError, "provide exactly one package path or --all" unless arguments.length == 1

      path = File.expand_path(arguments.first, root)
      raise InvocationError, "package path does not exist: #{arguments.first}" unless File.exist?(path)
      raise InvocationError, "package path is not a directory: #{arguments.first}" unless File.directory?(path)

      [[Package.new(path, root: root)], findings]
    end

    def verify_root!(root)
      valid = File.directory?(root) &&
              (File.exist?(File.join(root, ".git")) || File.directory?(File.join(root, "packages")))
      raise InvocationError, "repository root is not recognizable: #{root}" unless valid
    end

    def print_findings(findings, json, output)
      if json
        output.write(JSON.generate(findings.to_h))
        output.write("\n")
      else
        findings.each do |finding|
          output.puts "#{finding.severity.upcase} #{finding.path} #{finding.code}: #{finding.message}"
        end
      end
    end

    def terminal_failure(error, code, json, out, err, internal: false)
      message = internal ? "#{error.class}: #{error.message}" : error.message
      err.puts "honeycomb-validate: #{internal ? 'internal failure: ' : ''}#{message}"
      if json
        finding = Finding.new(path: "", code: code, message: message, severity: "error")
        out.write(JSON.generate([finding.to_h]))
        out.write("\n")
      end
      2
    end
  end
end
