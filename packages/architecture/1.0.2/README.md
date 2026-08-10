# Architecture

Turn an architecture brief into a concise, implementation-ready
`architecture.md`. The workflow collects untrusted web evidence before any
repository artifact exists, keeps the two evidence scopes separate, synthesizes only decision-relevant facts, drafts the
smallest coherent design, runs a bounded two-reviewer council, and records any
remaining owner decisions explicitly.

## Input

Create the task with a `brief.md` that states the desired outcome, important
constraints, known non-goals, and decisions that are already settled. A thin
brief is acceptable: the workflow labels assumptions and unknowns rather than
inventing facts.

## Durable artifacts

- `web-research.md` records current external evidence with stable URLs.
- `repo-research.md` maps relevant repository behavior and constraints.
- `research.md` is the decision-focused synthesis of both evidence streams.
- `draft.md` is the proposal revised by the council.
- `reviews/*.md` and `reviews/triage.md` preserve focused findings and their
  resolution.
- `architecture.md` is the terminal deliverable.

The main design is targeted at 2,500-5,000 words. Research detail stays in the
research artifacts instead of accumulating in the deliverable. The final
rubric requires traceable evidence, explicit constraints and tradeoffs,
component boundaries, data and control flow, operational and test strategy,
and a visible disposition for unresolved decisions and council findings.

## Execution identity and permissions

The package contains no agent, model, or effort choices. Installation maps each
declared planning or reviewer slot to project-selected agents. Repository
research can read the project repository but cannot use the network. Web
research runs first, can read only `brief.md`, and can search and fetch public
pages; it cannot read repository or later task artifacts. Later actors read
only task artifacts. No stage has shell, secret, or repository-write access.
