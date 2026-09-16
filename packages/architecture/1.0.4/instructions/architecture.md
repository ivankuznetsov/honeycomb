# Deliver the final architecture

Synthesize `brief.md`, `research.md`, the revised `draft.md`, and the latest
council triage into the terminal `architecture.md`. Do not copy review history
or research background that does not change a decision.

Target 2,500-4,500 words and never exceed 5,000 words. The deliverable must
contain:

1. outcome, scope, explicit constraints, success measures, and non-goals;
2. selected design and traceable repository `path:line` references plus
   external URLs for material factual claims;
3. components, ownership, interfaces, dependencies, and decision rationale;
4. ordered data-flow and control-flow coverage, including failure paths;
5. alternatives rejected and the concrete tradeoffs accepted;
6. security, operations, observability, migration, rollout, and rollback;
7. a test plan with acceptance evidence for each important risk;
8. `## Decisions needing owner input`, with safe defaults and consequences;
9. `## Reviewer findings`, as a compact table marking each blocking finding
   `resolved`, `deferred`, or `rejected`, with a reason and section link.

Do not claim a concern is resolved unless the corresponding design text
changed or a supported decision explains why it should not. A bounded council
may finish with unresolved findings; preserve them plainly rather than
claiming consensus. End with `<!-- COMPLETE -->` only when the document is
usable by implementers and honest about what remains unsettled.
