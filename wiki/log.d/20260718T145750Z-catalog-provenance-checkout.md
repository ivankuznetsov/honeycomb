## 2026-07-18 — Catalog CI fetches preserved provenance

- Changed the catalog publication source checkout to fetch complete history so
  provenance tests can read retained registry-original source commits.
- Added a workflow contract assertion that prevents a shallow checkout from
  silently returning to CI.
- Normalized empty JSON containers explicitly so catalog bytes are identical on
  the Ruby 3.2 GitHub runner and newer local Ruby runtimes.
