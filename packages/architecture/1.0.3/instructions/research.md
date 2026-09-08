# Synthesize decision evidence

Read `brief.md`, `repo-research.txt`, and `web-research.txt`. Return a concise
`research.md` that tells the architect what is known, what is inferred, and
what remains an owner decision. Do not perform new repository or web research.

Keep the synthesis below 2,500 words and include:

1. `## Decision frame` — outcome, success conditions, scope, and non-goals.
2. `## Evidence that constrains the design` — only load-bearing repository
   `path:line` references and external URLs, with fact separated from inference.
3. `## Existing system and required change` — the smallest accurate boundary
   and flow map needed for the proposal.
4. `## Settled constraints` — compatibility, security, operations, migration,
   rollout, and delivery facts.
5. `## Assumptions to validate` — reversible assumptions and how to test them.
6. `## Decisions needing owner input` — material choices that evidence cannot
   settle, including a safe default and consequence when possible.

Exclude background that does not affect a design decision. End with
`<!-- COMPLETE -->`.
