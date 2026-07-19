## 2026-07-19 — Make SEO timestamps portable across Ruby versions

- Explicitly loaded Ruby's `time` standard library before producing ISO 8601
  timestamps in the SEO provider metrics tool.
- Closed a Ruby 3.2 portability gap that Ruby 3.4's ambient load order masked.
- Retained deterministic prompt-only and provider-backed output without adding
  a gem or network dependency.
