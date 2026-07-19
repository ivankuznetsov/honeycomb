# Writing

Produce a grounded, publishable article through journalist research and an
adversarial writer/editor loop. Two independent editors review each revision;
the writer gets at most five rounds to reach consensus.

## Input

Create the task with `brief.md`: audience, purpose, desired form, voice, length,
deadline or freshness boundary, and any supplied sources. Mark claims or source
types that are mandatory.

## Outcomes and artifacts

- `research.md` is a source-to-claim research ledger. It explicitly records a
  `grounded` or `ungrounded` outcome.
- `draft.md` is the durable working draft revised between rounds.
- `reviews/*.md` and `reviews/triage.md` preserve every editor decision.
- `article.md` is the reader-facing deliverable. An ungrounded run produces an
  explicit non-publishable notice instead of invented prose.
- `verification.md` records claim support, material revision deltas, rounds,
  and the terminal reason: `ready`, `ungrounded`, or `five-round-cap`.

An editor that determines the premise is unsalvageable issues a
`changes_requested` decision with a `START OVER` required edit. The reviser
then replaces the draft while preserving the audit trail.

## Execution identity and permissions

The package chooses no agent, model, or effort. Installation maps the
journalist, writer, editors, and delivery slots. Only journalist research can
use current web sources; no actor receives shell, secret, or repository-write
access. Delivery may write only its task-local verification artifact.

## Provenance

This workflow is an adaptation of Agent Plugins commit
`e2caed2878ff1996f235ad0122bf7fea2eea3a27`, principally:

- `plugins/agent-writing/skills/writing/SKILL.md`
- `plugins/agent-writing/agents/journalist.md`
- `plugins/agent-writing/agents/writer.md`
- `plugins/agent-writing/agents/editor.md`
- `plugins/agent-writing/commands/write:full.md`

The behavior was rewritten for Hive's staged state and council verdict
contracts; no upstream agent identity is carried into the package. See
`NOTICE.md` for the upstream MIT attribution.
