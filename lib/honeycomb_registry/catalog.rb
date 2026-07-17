# frozen_string_literal: true

require "optparse"
require "time"

module HoneycombRegistry
  module Catalog
    SCHEMA = "honeycomb-catalog/v1"
    REPOSITORY_URL = "https://github.com/ivankuznetsov/honeycomb"
    Result = Struct.new(:document, :bytes, :findings, keyword_init: true)

    class Revoked < StandardError
      attr_reader :advisories

      def initialize(entry)
        @advisories = entry.fetch("advisories")
        super("honeycomb #{entry.fetch("name")}@#{entry.fetch("version")} is revoked")
      end
    end

    module_function

    def build(root:, evidence_path:)
      root = File.expand_path(root)
      findings = Findings.new
      discovery = Package.discover(root)
      findings.concat(discovery.findings)

      manifests = {}
      unless findings.errors?
        discovery.packages.each do |package|
          package_findings = Validator.validate(package)
          findings.concat(package_findings)
          next if package_findings.errors?

          manifest = SafeYAML.load_file(package.manifest_path)
          manifests[[package.name, package.version]] = manifest
        rescue SafeYAML::Invalid => e
          findings.concat([e.finding])
        end
      end

      evidence = ListingEvidence.load(evidence_path)
      findings.concat(evidence.findings)
      unless findings.errors?
        findings.concat(ListingEvidence.validate_bindings(evidence, manifests))
      end
      return Result.new(document: nil, bytes: nil, findings: findings) if findings.errors?

      eligible_records = evidence.records.select { |record| ListingEvidence.eligible?(record) }
      latest = latest_versions(eligible_records, findings)
      return Result.new(document: nil, bytes: nil, findings: findings) if findings.errors?

      entries = eligible_records.map do |record|
        manifest = manifests.fetch([record.fetch("name"), record.fetch("version")])
        project_entry(manifest, record, latest[record.fetch("name")])
      end
      entries.sort! do |left, right|
        name_comparison = left.fetch("name") <=> right.fetch("name")
        name_comparison.zero? ? SemVer.parse(left.fetch("version")) <=> SemVer.parse(right.fetch("version")) : name_comparison
      end
      document = {"schema" => SCHEMA, "entries" => entries}
      Result.new(document: document, bytes: CanonicalJSON.dump(document), findings: findings)
    rescue SystemCallError, IOError => e
      findings.add("catalog.json", "catalog.io", e.message)
      Result.new(document: nil, bytes: nil, findings: findings)
    end

    def generate(root:, evidence_path:, output_path: File.join(root, "catalog.json"))
      result = build(root: root, evidence_path: evidence_path)
      AtomicWrite.replace(output_path, result.bytes) unless result.findings.errors?
      result
    rescue SystemCallError, IOError => e
      result.findings.add("catalog.json", "catalog.write", e.message)
      result
    end

    def check(root:, evidence_path:, output_path: File.join(root, "catalog.json"))
      result = build(root: root, evidence_path: evidence_path)
      if !result.findings.errors? && (!File.file?(output_path) || File.binread(output_path) != result.bytes)
        result.findings.add("catalog.json", "catalog.drift",
                            "catalog is not the current canonical generated output")
      end
      result
    rescue SystemCallError, IOError => e
      result.findings.add("catalog.json", "catalog.unreadable", e.message)
      result
    end

    def latest_versions(records, findings)
      listed = records.select { |record| record["state"] == "listed" }
      listed.group_by { |record| record.fetch("name") }.each_with_object({}) do |(name, grouped), result|
        versions = grouped.map { |record| record.fetch("version") }
        result[name] = SemVer.latest(versions).to_s
      rescue SemVer::AmbiguousPrecedence => e
        findings.add("catalog.json", "catalog.ambiguous_latest", e.message)
      end
    end

    def project_entry(manifest, record, latest_version)
      lint = record.fetch("lint")
      approvals = record.fetch("approvals").select { |approval| approval["status"] == "approved" }
      head_sha = lint.fetch("head_sha")
      name = manifest.fetch("name")
      version = manifest.fetch("version")
      state = record.fetch("state")
      {
        "name" => name,
        "version" => version,
        "latest_version" => latest_version,
        "description" => manifest.fetch("description"),
        "release_tier" => record.fetch("release_tier"),
        "current_tier" => record.fetch("current_tier"),
        "permission_risk" => record.fetch("permission_risk"),
        "state" => state,
        "discoverable" => state == "listed",
        "exact_resolution" => state == "revoked" ? "blocked" : "allowed",
        "verification" => record.fetch("verification"),
        "history" => record.fetch("history"),
        "advisories" => record.fetch("advisories"),
        "author" => manifest.fetch("author"),
        "license" => manifest.fetch("license"),
        "hive_min_version" => manifest.fetch("hive_min_version"),
        "permissions" => manifest.fetch("permissions"),
        "install_command" => "hive workflow install honeycomb/#{name}",
        "package_url" => "#{REPOSITORY_URL}/tree/#{head_sha}/packages/#{name}/#{version}",
        "reviews_url" => approvals.first.fetch("review_url"),
        "source_sha" => manifest.fetch("source").fetch("revision"),
        "listing_approval" => {
          "release_sha256" => manifest.fetch("release_sha256"),
          "head_sha" => head_sha,
          "lint_checked_at" => lint.fetch("checked_at"),
          "approved_by" => approvals.map { |approval| approval.fetch("reviewer") },
          "approved_at" => approvals.max_by { |approval| Time.iso8601(approval.fetch("reviewed_at")) }.fetch("reviewed_at"),
          "reviews" => approvals.map do |approval|
            approval.slice("reviewer", "reviewed_at", "review_url", "evidence_digest")
          end
        }
      }
    end

    def discovery(document)
      Array(document.fetch("entries")).select { |entry| entry["discoverable"] == true }
    end

    def resolve(document, name:, version: nil)
      entries = Array(document.fetch("entries")).select { |entry| entry["name"] == name }
      selected = if version
                   entries.find { |entry| entry["version"] == version }
                 else
                   latest = entries.map { |entry| entry["latest_version"] }.compact.first
                   entries.find { |entry| entry["version"] == latest && entry["discoverable"] }
                 end
      raise Revoked, selected if selected && selected["state"] == "revoked"

      selected
    end
  end

  module CatalogCLI
    module_function

    def run(argv, out: $stdout, err: $stderr, default_root: nil)
      options = {check: false, root: default_root, evidence: nil, output: nil, help: false}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: honeycomb-catalog [--check] --evidence PATH"
        opts.on("--check", "Compare canonical bytes without writing") { options[:check] = true }
        opts.on("--evidence PATH", "Normalized listing evidence record set") { |value| options[:evidence] = value }
        opts.on("--root PATH", "Repository root") { |value| options[:root] = value }
        opts.on("--output PATH", "Catalog output path") { |value| options[:output] = value }
        opts.on("-h", "--help", "Show help") do
          out.puts opts
          options[:help] = true
        end
      end
      arguments = parser.parse(argv)
      return 0 if options[:help]
      raise InvocationError, "unexpected positional arguments" unless arguments.empty?
      raise InvocationError, "--evidence PATH is required" unless options[:evidence]

      root = File.expand_path(options[:root] || Dir.pwd)
      ValidatorCLI.verify_root!(root)
      evidence_path = File.expand_path(options[:evidence], root)
      raise InvocationError, "evidence path does not exist: #{options[:evidence]}" unless File.file?(evidence_path)
      output_path = File.expand_path(options[:output] || File.join(root, "catalog.json"), root)
      unless output_path == File.join(root, "catalog.json")
        raise InvocationError, "catalog output must be the repository root catalog.json"
      end

      result = if options[:check]
                 Catalog.check(root: root, evidence_path: evidence_path, output_path: output_path)
               else
                 Catalog.generate(root: root, evidence_path: evidence_path, output_path: output_path)
               end
      ManifestCLI.print_findings(result.findings, out)
      result.findings.errors? ? 1 : 0
    rescue OptionParser::ParseError, InvocationError => e
      err.puts "honeycomb-catalog: #{e.message}"
      2
    rescue StandardError => e
      err.puts "honeycomb-catalog: internal failure: #{e.class}: #{e.message}"
      2
    end
  end
end
