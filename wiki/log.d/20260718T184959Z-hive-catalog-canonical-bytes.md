# Match Hive catalog canonical bytes

- Replaced the registry catalog's indented JSON serialization with the exact
  compact, recursively key-sorted, NFC-normalized format consumed by released
  Hive v0.5.2.
- Added a fixed byte-vector regression and regenerated the populated production
  catalog from protected evidence with Hive v0.5.2 selected.
- Found the mismatch through a fresh public `hive workflow install
  honeycomb/task-inspect`, which failed closed before any workflow was
  installed.
