# frozen_string_literal: true

require "json"

module HoneycombSecurityLint
  class Renderer
    COMMENT_MARKER = "<!-- honeycomb-security-lint:v1 -->"

    def initialize(max_items:)
      @max_items = max_items
    end

    def comment(evidence)
      "#{COMMENT_MARKER}\n#{body(evidence)}"
    end

    def summary(evidence)
      body(evidence)
    end

    private

    def body(evidence)
      totals = evidence.fetch("totals")
      lines = [
        "## Honeycomb security lint",
        "",
        "**Verdict:** #{escape(evidence.fetch("verdict"))}",
        "",
        "Head SHA: `#{escape(evidence.fetch("head_sha"))}`  ",
        "Hard: #{totals.fetch("hard")} · Advisory: #{totals.fetch("advisory")} · Downgraded: #{totals.fetch("downgraded")}",
        ""
      ]
      if %w[awaiting_maintainer expired].include?(evidence.fetch("state"))
        lines << "A maintainer must apply `safe-to-validate` to this exact head before analysis can run."
        lines << ""
      end
      evidence.fetch("packages").each { |entry| render_honeycomb(lines, entry) }
      lines << "## Final Verdict"
      lines << ""
      lines << escape(evidence.fetch("verdict"))
      lines << ""
      lines.join("\n")
    end

    def render_honeycomb(lines, entry)
      identity = entry.fetch("identity")
      lines << "### Honeycomb `#{escape(identity.fetch("name"))}` `#{escape(identity.fetch("version"))}`"
      lines << ""
      lines << "Release: `#{escape(identity["release_sha256"] || "unavailable")}` · Verdict: **#{escape(entry.fetch("verdict"))}**"
      lines << ""
      section(lines, "Validator", entry.fetch("validator_findings")) do |finding|
        "`#{escape(finding.fetch("severity"))}` `#{escape(finding.fetch("code"))}` — #{escape(finding.fetch("message"))} (#{location(finding)})"
      end
      permission_items = entry["requested_permissions"] ? [entry.fetch("requested_permissions")] : []
      section(lines, "Permissions", permission_items) { |value| "`#{escape(JSON.generate(value))}`" }
      section(lines, "Commands", entry.fetch("commands")) do |command|
        "`#{escape(command.fetch("kind"))}` `#{escape(command.fetch("redacted"))}` (#{location(command)})"
      end
      section(lines, "Network", entry.fetch("hosts")) do |host|
        reason = host["reason"] ? " — #{escape(host["reason"])}" : ""
        "`#{escape(host.fetch("disposition"))}` `#{escape(host.fetch("host"))}`#{reason} (#{location(host)})"
      end
      deny_findings = entry.fetch("findings").reject { |finding| %w[secret pii].include?(finding["category"]) }
      section(lines, "Deny-pattern Hits", deny_findings) { |finding| render_finding(finding) }
      sensitive = entry.fetch("findings").select { |finding| %w[secret pii].include?(finding["category"]) }
      section(lines, "Secret/PII Findings", sensitive) { |finding| render_finding(finding) }
      section(lines, "Suppressions", entry.fetch("suppressions")) do |suppression|
        "`#{escape(suppression.fetch("status"))}` `#{escape(suppression.fetch("fingerprint"))}` — #{escape(suppression.fetch("reason"))}"
      end
      counts = entry.fetch("counts")
      lines << "#### Verdict"
      lines << ""
      lines << "**#{escape(entry.fetch("verdict"))}** — Hard: #{counts.fetch("hard")}, Advisory: #{counts.fetch("advisory")}, Downgraded: #{counts.fetch("downgraded")}"
      lines << ""
    end

    def section(lines, heading, values)
      lines << "#### #{heading}"
      lines << ""
      if values.empty?
        lines << "- None"
      else
        values.first(@max_items).each { |value| lines << "- #{yield value}" }
        omitted = values.length - @max_items
        lines << "- #{omitted} more items omitted; see the redacted JSON artifact." if omitted.positive?
      end
      lines << ""
    end

    def render_finding(finding)
      "`#{escape(finding.fetch("disposition"))}` `#{escape(finding.fetch("rule_id"))}` — " \
        "#{escape(finding.fetch("message"))}; #{escape(finding.fetch("redacted_evidence"))} (#{location(finding)})"
    end

    def location(value)
      path = escape(value.fetch("path", ""))
      line = value["line"]
      column = value["column"]
      suffix = line ? ":#{line}#{column ? ":#{column}" : ""}" : ""
      "`#{path}#{suffix}`"
    end

    def escape(value)
      text = Redactor.sanitize_text(value, max_bytes: 500)
      text = text.gsub(/javascript:/i, "javascript?")
      text = text.gsub("@", "@\u200b")
      text.gsub(/[\\`*_\[\]<>|#]/) { |character| "\\#{character}" }
    end
  end
end
