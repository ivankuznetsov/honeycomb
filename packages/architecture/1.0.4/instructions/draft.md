# Draft the architecture

Use `brief.md` and `research.md` to write a complete `draft.md`. Do not write
implementation code or expand the requested product scope.

Target 2,500-4,500 words and never exceed 5,000 words. Put supporting detail in
the research artifacts instead of repeating it. The draft must include:

- outcome, scope, non-goals, success measures, and explicit owner decisions;
- the selected architecture and why it is the smallest design that meets the
  success conditions;
- components with ownership, stable interfaces, and dependency direction;
- stepwise data and control flow, including persistence and external calls;
- failure modes, security boundaries, observability, migration, rollout, and
  rollback;
- alternatives rejected and concrete tradeoffs, not generic pros and cons;
- a test strategy tied to the important risks and interfaces;
- repository `path:line` references and external URLs for material factual
  claims;
- assumptions to validate and decisions still requiring owner input.

Do not turn research notes into a catalogue. End with `<!-- COMPLETE -->` when
reviewers can challenge individual decisions.
