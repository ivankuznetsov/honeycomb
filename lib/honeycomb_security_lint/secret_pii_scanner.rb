# frozen_string_literal: true

require "digest"

module HoneycombSecurityLint
  class SecretPiiScanner
    Pattern = Struct.new(:rule_id, :category, :severity, :regex, :message, :predicate, keyword_init: true)

    # Secret patterns are adapted from hive-bench's MIT-licensed portable
    # secret scanner at commit 432e730e. See NOTICE for attribution.
    PATTERNS = [
      Pattern.new(rule_id: "secret.private-key", category: "secret", severity: "hard",
                  regex: /-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----/,
                  message: "Private key material detected"),
      Pattern.new(rule_id: "secret.github-token", category: "secret", severity: "hard",
                  regex: /\bgh[pousr]_[A-Za-z0-9]{20,}\b/, message: "GitHub credential detected"),
      Pattern.new(rule_id: "secret.openai-key", category: "secret", severity: "hard",
                  regex: /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/, message: "OpenAI credential detected"),
      Pattern.new(rule_id: "secret.anthropic-key", category: "secret", severity: "hard",
                  regex: /\bsk-ant-[A-Za-z0-9_-]{20,}\b/, message: "Anthropic credential detected"),
      Pattern.new(rule_id: "secret.aws-access-key", category: "secret", severity: "hard",
                  regex: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/, message: "AWS access key detected"),
      Pattern.new(rule_id: "secret.slack-token", category: "secret", severity: "hard",
                  regex: /\bxox[baprs]-[0-9A-Za-z-]{10,}\b/, message: "Slack credential detected"),
      Pattern.new(rule_id: "secret.google-api-key", category: "secret", severity: "hard",
                  regex: /\bAIza[0-9A-Za-z_-]{30,}\b/, message: "Google API credential detected"),
      Pattern.new(rule_id: "secret.jwt", category: "secret", severity: "hard",
                  regex: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/,
                  message: "JWT-shaped credential detected"),
      Pattern.new(rule_id: "secret.bearer", category: "secret", severity: "hard",
                  regex: /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}={0,2}\b/i,
                  message: "Bearer credential detected"),
      Pattern.new(rule_id: "secret.generic-assignment", category: "secret", severity: "hard",
                  regex: /\b(?:api[_-]?key|client[_-]?secret|password|token)\b\s*[:=]\s*["']([^"'\s]{16,})["']/i,
                  predicate: ->(match) { entropy(match[1].to_s) >= 3.2 },
                  message: "High-entropy credential assignment detected"),
      Pattern.new(rule_id: "pii.payment-card", category: "pii", severity: "hard",
                  regex: /(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/,
                  predicate: ->(match) { luhn_valid?(match[0]) },
                  message: "Checksum-valid payment card number detected"),
      Pattern.new(rule_id: "pii.government-id", category: "pii", severity: "hard",
                  regex: /\b(?:ssn|social\s+security(?:\s+number)?|national\s+id)\s*[:#-]?\s*(\d{3}-\d{2}-\d{4})\b/i,
                  message: "Context-labeled government identifier detected"),
      Pattern.new(rule_id: "pii.email", category: "pii", severity: "advisory",
                  regex: /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i,
                  message: "Email address observed"),
      Pattern.new(rule_id: "pii.phone", category: "pii", severity: "advisory",
                  regex: /(?<![A-Z0-9])(?:\+?\d[\s().-]*){10,15}(?![A-Z0-9])/i,
                  predicate: ->(match) { match[0].scan(/\d/).length.between?(10, 15) },
                  message: "Phone-like personal data observed")
    ].freeze

    class LimitExceeded < StandardError; end

    def initialize(max_findings: nil)
      @max_findings = max_findings
    end

    class << self
      def entropy(value)
        return 0.0 if value.empty?

        counts = value.each_char.tally
        counts.values.sum do |count|
          probability = count.fdiv(value.length)
          -probability * Math.log2(probability)
        end
      end

      def luhn_valid?(value)
        digits = value.scan(/\d/).map(&:to_i)
        return false unless digits.length.between?(13, 19)
        return false if digits.uniq.length == 1

        sum = digits.reverse.each_with_index.sum do |digit, index|
          if index.odd?
            doubled = digit * 2
            doubled > 9 ? doubled - 9 : doubled
          else
            digit
          end
        end
        (sum % 10).zero?
      end
    end

    def scan(files)
      findings = []
      files.select(&:text).each { |file| scan_source(file, findings) }
      findings.sort_by { |finding| [finding["path"], finding["line"], finding["column"], finding["rule_id"]] }
    end

    def scan_source(file, findings = [])
      file.text.each_line.with_index(1) do |line, line_number|
        PATTERNS.each do |pattern|
          line.to_enum(:scan, pattern.regex).each do
            match = Regexp.last_match
            next if pattern.predicate && !pattern.predicate.call(match)

            if @max_findings && findings.length >= @max_findings
              raise LimitExceeded, "secret and PII finding count exceeds policy"
            end
            findings << finding(pattern, file.path, line_number, match.begin(0) + 1, match[0])
          end
        end
      end
      findings
    end

    def redact_text(value)
      redacted = value.to_s.dup
      PATTERNS.each do |pattern|
        redacted.gsub!(pattern.regex) do |match|
          current = Regexp.last_match
          pattern.predicate && !pattern.predicate.call(current) ? match : Redactor.finding_evidence(pattern.rule_id, match)
        end
      end
      Redactor.sanitize_text(redacted)
    end

    private

    def finding(pattern, path, line, column, matched)
      fingerprint = Digest::SHA256.hexdigest(
        [pattern.rule_id, path, line, column, matched].join("\0")
      )
      {
        "rule_id" => pattern.rule_id,
        "category" => pattern.category,
        "original_severity" => pattern.severity,
        "disposition" => pattern.severity,
        "path" => path,
        "line" => line,
        "column" => column,
        "fingerprint" => fingerprint,
        "redacted_evidence" => Redactor.finding_evidence(pattern.rule_id, matched),
        "message" => pattern.message,
        "request" => nil,
        "approval" => nil
      }
    end
  end
end
