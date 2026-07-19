# Architecture

Turn a repository-aware architecture brief into an implementation-ready
`architecture.md`. The workflow inspects the repository, drafts the smallest
coherent design, runs two independent council reviews, revises to consensus,
and produces a final architecture record.

## Input

Create the task with a `brief.md` that states the desired outcome, important
constraints, known non-goals, and any decisions that are already settled. A
thin brief is acceptable: the research stage records gaps instead of inventing
facts.

## Durable artifacts

- `research.md` maps the relevant repository evidence and constraints.
- `draft.md` is the versioned proposal revised by the council.
- `reviews/*.md` and `reviews/triage.md` preserve findings and their resolution.
- `architecture.md` is the terminal deliverable.

The final rubric requires repository evidence links, explicit constraints and
tradeoffs, component boundaries, data and control flow, operational and test
strategy, and a visible disposition for every council finding.

## Execution identity and permissions

The package contains no agent, model, or effort choices. Installation maps each
declared planning or reviewer slot to project-selected agents. Research can
read the repository; later actors read only task artifacts. No stage has shell,
network, secret, or repository-write access.
