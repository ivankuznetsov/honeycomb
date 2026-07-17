# 2026-07-17: Harden trust and review enforcement

- Reject changes to package version roots already present at the exact base
  revision, requiring fixes to publish a new SemVer directory.
- Added a strict community-review validator and trusted-base workflow that bind
  the authenticated PR author and review identities without executing submitted
  code.
- Preserved the catalog v1 designated-approval `reviews_url` contract unchanged
  and versioned the nullable `community_reviews_url` extension as catalog v2.
- Required prior normalized listing evidence during export, retaining
  unselected records and carrying lifecycle, tier, verification, history, and
  advisories across lint refreshes.
