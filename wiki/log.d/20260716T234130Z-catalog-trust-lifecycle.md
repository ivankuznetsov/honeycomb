# 2026-07-16: Ship catalog trust and lifecycle contract

- Replaced the ambiguous evidence tier/approval projection with independent
  release/current tiers, permission risk, lifecycle state, reviewer decisions,
  verification, ordered history, and advisories.
- Required two distinct current maintainer approvals for high-risk releases and
  exact digest/workflow identity evidence for current or historic Verified
  releases.
- Retained dual-gated soft-hidden, yanked, and revoked versions in canonical
  catalog data while limiting discovery/latest to listed releases.
- Added fail-closed revoked exact resolution carrying mandatory public
  advisories, plus checked-in listing-evidence and catalog schemas.
