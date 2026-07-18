# Close the Cloudflare production-check gap

- Confirmed Cloudflare replaced the stale in-progress check record with
  successful Workers check `88115025357` on exact hive-site commit
  `f5979cca40a0a2e86a7cafbae581f2c97323b3bd`.
- Removed the temporary acknowledgement gap; both production hostnames and the
  exact-commit provider check are now green.
