## 2026-07-22 — Reap Async Fix Docker attempt children

- Added Docker's init reaper to the Async Fix acceptance container so orphaned
  Hive attempt descendants cannot remain as zombies under the Ruby fixture at
  PID 1.
- Locked the reaper into the Docker contract after live recovery evidence
  showed successful JSON could precede durable attempt completion long enough
  to trip the command timeout.
- Preserved the digest pin, disabled network, read-only source snapshots,
  default-deny command boundary, bounded timeout, and cleanup requirements.
