## [2026-08-02T21:20:00Z] root-cause-repair - preserve final evidence time

- Extended repair and verification from one hour to two hours after the clean live repair implemented the provider boundary, added hostile-path coverage and documentation, and ran two broad Hive checkpoints, but timed out before it could write the final authority report.
- Kept the failed attempt fail-closed: its partial target bytes are not adopted by retry. Acceptance must restart from a clean checkpointed baseline.
