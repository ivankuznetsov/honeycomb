# Reviewer Panel Hive mapping acceptance

- Installed both managed-repair candidates from an isolated disposable registry
  with released Hive 0.6.0 in a throwaway Ruby 3.4 Docker container.
- Confirmed Reviewer Panel installs, captures task provenance, and executes its
  deterministic Hive council when every slot is explicitly mapped to a
  compatible Claude profile.
- Recorded that Hive 0.6.0's non-interactive suggested-agent rotation can choose
  an incompatible Codex profile for a bounded read-only reviewer slot. Hive
  rejects that suggestion at admission, so automation must pass compatible
  per-slot mappings until Hive filters suggestions by slot policy.
