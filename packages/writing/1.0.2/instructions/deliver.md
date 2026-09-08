# Deliver the article and verification

Read `brief.md`, `research.md`, the final `draft.md`, every `reviews/*.md`
artifact, and `reviews/triage.md`.

Before returning the article, use the allowed edit operation to create
`verification.md` with:

- `grounding: grounded|ungrounded`;
- `terminal_reason: ready|ungrounded|five-round-cap`;
- the number of completed editorial rounds;
- a source-to-claim checklist for every material factual claim retained;
- material revision deltas across rounds;
- unresolved editor findings, if any, with their effect on publishability.

Choose `ready` only when both editors reached consensus and no unsupported
material claim remains. Choose `five-round-cap` when the council exhausted five
rounds without consensus; clearly label both artifacts non-publishable and list
the blockers. Choose `ungrounded` when the research outcome cannot support a
safe article.

Return the complete reader-facing `article.md`. Do not include workflow notes in
a ready article. For either non-ready outcome, return a prominent
`NOT PUBLISHABLE` notice and the grounded material or research gap rather than
invented prose. End both files with `<!-- COMPLETE -->`.
