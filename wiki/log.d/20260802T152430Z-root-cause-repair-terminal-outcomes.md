# Bind Root Cause Repair terminal outcomes

- Declared the candidate certificate's `verified` and `not-reproduced` values
  as completing outcomes and `blocked` as a blocking outcome.
- Documented that a compatible Hive runtime preserves blocked certificates as
  active, visible, explicitly retryable errors instead of archived completion.
- Pinned the candidate-only execution gate to Hive
  `ca0c429c0f7cbf3c912f2ffdd01b04a7890374b0` in a separate Ruby process so
  released-package compatibility tests retain their immutable Hive 0.6.7 pin.
- Left the immutable 1.0.0 package, manifests, catalog, and publication state
  unchanged.
