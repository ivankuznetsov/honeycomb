# Deliver the final architecture

Synthesize `brief.md`, `research.md`, the revised `draft.md`, and all council
review and triage artifacts into the terminal `architecture.md`.

The deliverable must contain:

1. outcome, scope, explicit constraints, and non-goals;
2. selected design and repository evidence links for existing behavior;
3. components, ownership, interfaces, and dependencies;
4. ordered data-flow and control-flow coverage, including failure paths;
5. alternatives rejected and the concrete tradeoffs accepted;
6. security, operations, observability, migration, rollout, and rollback;
7. a test plan with acceptance evidence for each important risk;
8. `## Reviewer findings` with every council finding marked `resolved`,
   `deferred`, or `rejected`, plus the reason and relevant section link.

Do not claim a reviewer concern is resolved unless the corresponding design
text changed or a supported decision explains why it should not. End with
`<!-- COMPLETE -->` only when the document is ready for implementers.
