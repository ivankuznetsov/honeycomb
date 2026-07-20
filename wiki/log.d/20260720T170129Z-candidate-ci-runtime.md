## 2026-07-20 — Candidate CI verifies the pinned Hive checkout

- Passed the separately checked-out Hive root to source-contract tests through
  `HONEYCOMB_HIVE_SOURCE` as well as exposing its libraries through `RUBYLIB`.
- Kept repository-state flag coverage portable across Git versions that accept
  `--fsmonitor-valid` but do not set the bit when no fsmonitor is available.
