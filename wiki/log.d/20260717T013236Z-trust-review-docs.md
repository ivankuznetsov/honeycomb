# 2026-07-17: Ship trust and review policy contracts

- Added the canonical contribution, security, trust-tier, and community-review
  policies, plus a public-safe report-to-delist issue form.
- Moved catalog community-review discovery to the mutable external
  `reviews/<name>/<version>/` namespace while retaining immutable designated
  approval audit URLs separately.
- Added dependency-free contract coverage for policy links, issue-form YAML,
  review records, landed schema identities/enums, numeric targets, and review
  isolation from immutable releases and listing authority.
- Recorded GitHub private-vulnerability-reporting enablement as a rollout gap;
  the security policy provides the repository owner's published private email
  fallback.
