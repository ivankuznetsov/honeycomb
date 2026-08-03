---
title: Keep the Root Cause Repair CI runtime pin coherent
---

- Advanced the catalog publication workflow's Root Cause Repair Hive checkout
  to the same immutable revision required by the candidate execution tests.
- Reused the candidate revision constant in the workflow regression so future
  runtime advances cannot leave CI exercising a stale Hive checkout.
