# frozen_string_literal: true

require "stringio"

module HoneycombRegistry
  module HiveCompatibility
    Runtime = Struct.new(:version, :parser, keyword_init: true)

    module_function

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
