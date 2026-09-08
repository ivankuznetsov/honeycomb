# Architecture

Turn an architecture brief into a concise, implementation-ready
`architecture.md`. The workflow keeps repository and untrusted web evidence in
separate raw artifacts, synthesizes only decision-relevant facts, drafts the
smallest coherent design, runs a bounded two-reviewer council, and records any
remaining owner decisions explicitly.

## Input

Create the task with a `brief.md` that states the desired outcome, important
constraints, known non-goals, and decisions that are already settled. A thin
brief is acceptable: the workflow labels assumptions and unknowns rather than
inventing facts.

## Durable artifacts

- `repo-research.txt` maps relevant repository behavior and constraints.
- `web-research.txt` records current external evidence with stable URLs.
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
declared planning or reviewer slot to project-selected agents. Repository and
web research remain separate research activities, not security boundaries.
The raw `.txt` evidence files are not automatically embedded in later prompts:
synthesis reads them deliberately and emits decision-focused `research.md`.

## Trusted execution

This owner-trusted workflow explicitly uses `permissions: yolo` for every
agent, council, reviewer, and reviser. Agents use their normal tools and write
task artifacts directly; Hive adds no workflow sandbox or tool allowlist.
This is high-risk execution with the invoking user's normal access. Install
only workflows you trust. Task scope, evidence requirements, owner approvals,
and publication checks still apply; trust does not authorize unrelated changes.
