# frozen_string_literal: true

require "digest"

module HoneycombSecurityLint
  class RuleEngine
    Rule = Struct.new(:rule_id, :regex, :message, keyword_init: true)

    RULES = [
      Rule.new(rule_id: "deny.pipe-to-shell",
               regex: /\b(?:curl|wget)\b[^\n|]*\|\s*["']?(?:sudo\s+)?(?:ba|z)?sh(?:["']|\s|\z)|\b(?:iwr|invoke-webrequest)\b[^\n|]*\|\s*(?:iex|invoke-expression)\b/i,
               message: "Network response is piped to a shell"),
      Rule.new(rule_id: "deny.credential-read",
               regex: %r{(?:~|\$\{?HOME\}?)/(?:\.ssh|\.aws|\.config/gh|\.kube/config|\.npmrc|\.netrc|\.git-credentials|\.docker/config\.json)|/\.aws/credentials}i,
               message: "Command reads a credential-bearing path"),
      Rule.new(rule_id: "deny.environment-dump",
               regex: /\A\s*(?:(?:env|printenv)(?:\z|(?!\s*(?:=|<<))\s+)|set\s*\z)/i,
               message: "Command dumps environment values"),
      Rule.new(rule_id: "deny.path-traversal", regex: %r{(?:\A|[\s"'])\.\./},
               message: "Command contains parent traversal"),
      Rule.new(rule_id: "deny.encoded-exfiltration",
               regex: /\b(?:base64|openssl\s+enc|gzip|tar|zip)\b[^\n|;]*(?:\||;|&&)[^\n]*(?:curl|wget|iwr|invoke-webrequest)\b|\b(?:curl|wget)\b[^\n]*(?:--data(?:-binary)?|-d)\s+[^\n]*(?:base64|gzip|tar|zip)/i,
               message: "Encoded or compressed data is sent to a network client")
    ].freeze

    class LimitExceeded < StandardError; end

    def initialize(max_findings: nil)
      @max_findings = max_findings
    end

    def analyze(commands)
      findings = []
      commands.each do |command|
        RULES.filter_map do |rule|
          match = rule.regex.match(command.raw)
          finding(rule.rule_id, rule.message, command, match.begin(0) + 1, match[0]) if match
        end.each { |entry| append(findings, entry) }
      end
      download_then_execute(commands).each { |entry| append(findings, entry) }
      findings.uniq { |entry| entry["fingerprint"] }
              .sort_by { |entry| [entry["path"], entry["line"], entry["column"], entry["rule_id"]] }
    end

    private

    def download_then_execute(commands)
      downloads = {}
      commands.each do |command|
        if (match = command.raw.match(/\b(?:curl|wget)\b.*?(?:-o|--output|-O)\s+([A-Za-z0-9_.\/-]+)/i))
          downloads[File.basename(match[1])] = command
        end
      end
      commands.each_with_object([]) do |command, findings|
        candidates = command.raw.scan(/[A-Za-z0-9_.\/-]+/).map { |token| File.basename(token) }.uniq
        candidates.each do |basename|
          download = downloads[basename]
          next unless download
          next unless command.raw.match?(%r{(?:\b(?:bash|sh|zsh|chmod)\b[^\n]*|\./)\b?#{Regexp.escape(basename)}\b})
          next if command.equal?(download)

          findings << finding("deny.download-then-execute", "Downloaded content is subsequently executed",
                              command, 1, basename)
        end
      end
    end

    def append(findings, finding)
      if @max_findings && findings.length >= @max_findings
        raise LimitExceeded, "rule finding count exceeds policy"
      end
      findings << finding
    end

    def finding(rule_id, message, command, offset, matched)
      fingerprint = Digest::SHA256.hexdigest(
        [rule_id, command.path, command.line, command.column + offset - 1, matched].join("\0")
      )
      {
        "rule_id" => rule_id,
        "category" => "deny",
        "original_severity" => "hard",
        "disposition" => "hard",
        "path" => command.path,
        "line" => command.line,
        "column" => command.column + offset - 1,
        "fingerprint" => fingerprint,
        "redacted_evidence" => SecretPiiScanner.new.redact_text(matched),
        "message" => message,
        "request" => nil,
        "approval" => nil
      }
    end
  end
end
