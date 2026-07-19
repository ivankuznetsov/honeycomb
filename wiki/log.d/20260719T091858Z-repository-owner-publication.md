# Add explicit repository-owner publication authority

- Added a protected first-party Community publication lane for repositories
  where the admin namespace owner is the only collaborator.
- Kept independent one/two-maintainer approval counts for community packages
  and kept Verified promotion dependent on independent review.
- Required canonical-repository authorship, exact-head passing lint, no
  suppressions, an exact responsibility acknowledgement, audit notes, and an
  immutable Actions-run URL plus stable GitHub workflow creation time, making
  workflow retries byte-for-byte idempotent.
- Preserved historical approval evidence by treating a missing authority field
  as `independent`.
