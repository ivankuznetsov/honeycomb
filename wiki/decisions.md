# Decisions

Record durable technical decisions here with date, context, decision, and
consequence.

## 2026-07-09: Published Workflow Packages Are Honeycombs

Context: commit `ab7861a` updated the README to use a consistent product term
for publishable Hive workflows. The Hive inbox task notes also carry the same
naming guidance.

Decision: call each published workflow package a "honeycomb" in user-facing
surfaces. The public catalog URL is `hive.sh/honeycombs`, and the documented
future install form is `hive workflow install honeycomb/<name>`.

Consequence: future manifest docs, CLI output, CI comments, README catalog
sections, and review copy should use "honeycomb" for listed workflow packages.
The repository should not introduce competing terms such as "package" as the
primary user-facing name, except where implementation details require it.
