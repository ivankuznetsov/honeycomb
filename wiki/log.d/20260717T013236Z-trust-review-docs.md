# 2026-07-17: Ship trust and review policy contracts

- Added the canonical contribution, security, trust-tier, and community-review
  policies, plus a public-safe report-to-delist issue form.
- Added nullable catalog community-review discovery for the mutable external
  `reviews/<name>/<version>/` namespace while preserving the v1 `reviews_url`
  designated-approval meaning.
- Added dependency-free contract coverage for policy links, issue-form YAML,
  review records, landed schema identities/enums, numeric targets, and review
  isolation from immutable releases and listing authority.
- Enabled and verified GitHub private vulnerability reporting; the security
  policy also retains the repository owner's published email as an outage
  fallback.
- Review remediation added immutable-version rejection, trusted-base production
  review validation, durable lifecycle projection across exports, and a direct
  issue-composer link.
