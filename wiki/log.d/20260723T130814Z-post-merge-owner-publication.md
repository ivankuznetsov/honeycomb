# Permit exact post-merge owner publication

- Kept independent listing approval bound to an open pull request and current
  non-author review.
- Allowed the protected repository-owner lane to use an exact merged
  first-party pull request only when the merge is present in the workflow's
  pinned default-branch snapshot.
- Required the trusted snapshot's package bytes to regenerate the reviewed
  release digest and registry-original provenance to preserve source ancestry
  plus exact declared source bytes, so stale, reverted, changed, orphaned, or
  missing packages fail closed.
- Preserved the exact owner acknowledgement, audit notes, passing lint, no
  suppressions, canonical-repository authorship, and protected Actions audit
  URL requirements.
