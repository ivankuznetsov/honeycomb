## 2026-07-18 — Make evidence digests runtime-independent

- Replaced `JSON.pretty_generate` as the canonical contract encoder because
  JSON 2.6 and JSON 2.9+ serialize empty arrays differently.
- Defined sorted object keys, two-space layout, compact empty containers,
  explicit UTF-8 string escaping, and integer-only numeric rendering in
  registry code so GitHub-issued evidence can be verified offline.
- Added a fixed digest vector and rejection coverage for values without a
  portable contract encoding.
