# Architecture 1.0.2 source candidate

**Action:** Added an immutable Architecture 1.0.2 source candidate that keeps
repository research network-free, gives web research exact read access only to
`brief.md`, and stores both raw evidence streams as non-Markdown `.txt` state.
Only synthesis reads those raw artifacts and emits decision-relevant evidence.
The package caps the main document at 5,000 words, bounds the council at two
rounds, and preserves unresolved owner decisions explicitly. Portable runners
that cannot enforce the web stage's exact-file read scope are rejected.

**Evidence:** Focused flagship package tests cover stage order, network and
repository isolation, council bounds, execution-identity neutrality, and the
new quality instructions. The catalog remains pinned to listed Architecture
1.0.1 until 1.0.2 completes protected lint and publication approval.
