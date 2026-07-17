# 2026-07-16: Ship trusted listing approval issuance

- Added a protected default-branch workflow that verifies maintainer
  permission, current review, exact PR head, authoritative lint status,
  protected paths, artifact digest, and honeycomb release identity.
- Added immutable, idempotent lint and reviewer-record persistence on the
  dedicated `honeycomb-evidence` branch without changing the approved head.
- Added an offline, explicit-selection exporter from a checked-out evidence
  snapshot into the normalized catalog reader contract.
- Kept protected environment/branch creation and the live dispatch canary as
  post-merge repository rollout work.
