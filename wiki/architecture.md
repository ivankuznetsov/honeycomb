# Architecture

`honeycomb` is currently a scaffold for a reviewed library of publishable Hive
workflow packages called honeycombs. The repository has documentation, LLM wiki
maintenance files, and Hive task state, but no application source tree,
executable entrypoint, routes, handlers, package catalog, or CI implementation
yet.

## Current Repository Shape

- `README.md` is the authoritative public description at this stage.
- `.hive-state/` contains inbox tasks for the initial registry, review, and
  catalog work.
- `wiki/` contains agent-facing project context and update history.
- `raw/notes/` is reserved for raw notes, currently empty except for
  `.gitkeep`.

## Intended Product Shape

The README describes a honeycomb as a Hive workflow package made from a
`workflow.yml` descriptor, stage instructions, and a manifest carrying version,
author, permissions summary, and sha256 integrity information.

The current Hive inbox tasks outline the planned implementation:

- task 1848: package registry layout, manifest schema, generated `catalog.json`,
  and validator script;
- task 1849: security lint CI for submitted packages;
- task 1850: trust model and review process docs;
- task 1851: seed catalog entries.

The README notes Hive-side tasks 1852/1853 for install verbs. Those tasks are
not represented as local implementation in this repository.

## Runtime Flow Status

There is no confirmed runtime flow in this repository yet. The documented future
flow is: publish honeycombs to a reviewed catalog, expose them at
`hive.sh/honeycombs`, and install one through
`hive workflow install honeycomb/<name>` once the Hive CLI integration exists.
