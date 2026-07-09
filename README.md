# honeycomb

A library of **honeycombs** — publishable workflows for
[hive](https://github.com/ivankuznetsov/hive). Publish yours, install others',
every listing security-reviewed: a honeycomb's stage instructions are agent
prompts that run with repository write access, so the review gate is the
product.

- Catalog: **hive.sh/honeycombs**
- Install: `hive workflow install honeycomb/<name>` (verbs land with hive tasks 1852/1853)
- A *honeycomb* = descriptor (`workflow.yml`) + stage instructions + manifest
  (version, author, permissions summary, sha256 integrity)

Status: scaffolding. Architecture tasks live in `.hive-state` (1848–1851 here,
1852–1853 in hive).
