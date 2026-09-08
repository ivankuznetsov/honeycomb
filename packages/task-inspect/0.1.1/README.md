# Task Inspect honeycomb

Produce a concise inventory of the current Hive task workspace and record it
in `inspect.md`. Inspection does not authorize changes to the inspected inputs.

## Install

```sh
hive workflow install honeycomb/task-inspect
```

## Permissions

Task Inspect uses normal agent tools. The generated manifest discloses its
high-risk trusted execution policy.

## Trusted execution

This owner-trusted workflow explicitly uses `permissions: yolo` for every
agent, council, reviewer, and reviser. Agents use their normal tools and write
task artifacts directly; Hive adds no workflow sandbox or tool allowlist.
This is high-risk execution with the invoking user's normal access. Install
only workflows you trust. Task scope, evidence requirements, owner approvals,
and publication checks still apply; trust does not authorize unrelated changes.
