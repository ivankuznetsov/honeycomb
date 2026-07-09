# Project Wiki

This wiki is maintained for coding agents. Read it before planning,
implementation, review, or debugging work, and update it when project facts
change.

## Core Pages

- [[architecture]] - system shape, runtime flows, and important modules.
- [[command-api-surface]] - documented commands, catalog surface, and current
  implementation status.
- [[decisions]] - durable design decisions and tradeoffs.
- [[dependencies]] - runtime, development, and service dependencies.
- [[gaps]] - missing, uncertain, or stale wiki coverage.

## Update Protocol

- Update affected pages when code behavior, architecture, commands, or
  dependencies change.
- Add a new `wiki/log.d/<timestamp>-<slug>.md` fragment after every wiki update,
  but do not edit the compiled `wiki/log.md` in feature PRs.
- Record uncertainty in [[gaps]] instead of inventing facts.
