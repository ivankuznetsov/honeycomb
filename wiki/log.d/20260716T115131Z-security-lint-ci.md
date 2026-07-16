# 2026-07-16: Ship fork-safe security lint CI

- Added deterministic Ruby security lint for changed honeycomb versions,
  including validator integration, bounded content discovery, secret/PII
  redaction, static instruction rules, permission comparison, exact suppression
  dispositions, canonical JSON evidence, and matching reviewer Markdown.
- Added a read-only `pull_request` analyzer and default-branch `workflow_run`
  reporter with hostile artifact verification, protected-path refusal, stale-run
  guards, one owned comment, label expiry, and authoritative
  `honeycomb/security-lint` status.
- Added strict lint/approval-to-catalog adaptation and black-box proof that only
  a current passing lint plus current human approval lists a release.
- Documented repository settings and the post-merge fork canary; maintainer
  approval issuance/storage remains a tracked gap owned by task 1850.
