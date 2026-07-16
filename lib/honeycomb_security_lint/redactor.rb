# frozen_string_literal: true

module HoneycombSecurityLint
  module Redactor
    CONTROL_PATTERN = /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/

    module_function

    def finding_evidence(rule_id, matched)
      "[redacted #{rule_id}; #{matched.to_s.bytesize} bytes]"
    end

    def sanitize_text(value, max_bytes: 500)
      text = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
      text = text.gsub(CONTROL_PATTERN, "?").gsub("::", "\\::")
      return text if text.bytesize <= max_bytes

      text.byteslice(0, max_bytes).to_s.force_encoding(Encoding::UTF_8).scrub + "…"
    end
  end
end
