# frozen_string_literal: true

require "time"

module HoneycombSecurityLint
  module EvidenceSnapshot
    MAX_RECORD_BYTES = 2 * 1024 * 1024

    class Invalid < StandardError; end

    module_function

    def export(root:, lint_paths:, checked_at:, release_tier:)
      snapshot = File.realpath(root)
      raise Invalid, "evidence snapshot is not a directory" unless File.directory?(snapshot)
      paths = Array(lint_paths)
      raise Invalid, "at least one lint record is required" if paths.empty?

      records = paths.sort.flat_map do |path|
        lint = read_lint(snapshot, path)
        approvals = approvals_for(snapshot, lint)
        ListingEvidenceAdapter.build(
          lint_evidence: lint, approvals: approvals, checked_at: checked_at,
          release_tier: release_tier
        ).fetch("records")
      end
      duplicate = records.group_by { |record| record.values_at("name", "version") }
                         .find { |_key, grouped| grouped.length > 1 }
      raise Invalid, "selected lint records contain a duplicate honeycomb version" if duplicate

      {
        "schema" => HoneycombRegistry::ListingEvidence::SCHEMA,
        "records" => records.sort_by do |record|
          [record.fetch("name"), HoneycombRegistry::SemVer.parse(record.fetch("version"))]
        end
      }
    rescue Contracts::Invalid, HoneycombRegistry::SemVer::Invalid, SystemCallError, IOError => e
      raise Invalid, Redactor.sanitize_text(e.message)
    end

    def read_lint(snapshot, path)
      absolute = safe_record_path(snapshot, path)
      evidence = Contracts.parse_evidence(read_regular(absolute))
      unless Contracts.artifact_digest_valid?(evidence)
        raise Invalid, "lint record content digest is invalid"
      end
      evidence
    end

    def approvals_for(snapshot, lint)
      records = lint.fetch("packages").flat_map do |package|
        identity = package.fetch("identity")
        HoneycombRegistry::SemVer.parse(identity.fetch("version"))
        directory = File.join(
          snapshot, "approvals", identity.fetch("name"), identity.fetch("version"),
          lint.fetch("head_sha")
        )
        next [] unless File.directory?(directory)
        safe_record_path(snapshot, directory)
        Dir.children(directory).sort.map do |basename|
          raise Invalid, "approval snapshot contains an unexpected entry" unless basename.match?(/\A[A-Za-z0-9-]+\.json\z/)
          path = File.join(directory, basename)
          document = Contracts.parse_approvals(read_regular(path))
          unless document.fetch("approvals").length == 1
            raise Invalid, "stored approval record must contain exactly one approval"
          end
          document.fetch("approvals").first
        end
      end
      records.group_by do |approval|
        approval.values_at("name", "version", "path") + [approval.fetch("reviewer").downcase]
      end.values.map do |decisions|
        ranked = decisions.map { |approval| [approval, Time.iso8601(approval.fetch("reviewed_at"))] }
        newest_at = ranked.map(&:last).max
        newest = ranked.select { |_approval, reviewed_at| reviewed_at == newest_at }
        raise Invalid, "reviewer decisions have an ambiguous audit timestamp" unless newest.length == 1

        newest.first.first
      end
    end

    def safe_record_path(snapshot, path)
      absolute = File.expand_path(path, snapshot)
      prefix = snapshot.end_with?(File::SEPARATOR) ? snapshot : "#{snapshot}#{File::SEPARATOR}"
      unless absolute.start_with?(prefix) || absolute == snapshot
        raise Invalid, "evidence record escapes the checked-out snapshot"
      end
      real = File.realpath(absolute)
      unless real.start_with?(prefix) || real == snapshot
        raise Invalid, "evidence record resolves outside the checked-out snapshot"
      end
      absolute
    end

    def read_regular(path)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.size <= MAX_RECORD_BYTES
        raise Invalid, "evidence record is not a bounded regular file"
      end
      File.binread(path)
    end
  end
end
