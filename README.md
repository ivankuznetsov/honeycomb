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

The repository now ships the independent `honeycomb-manifest/v1` package
contract, offline Ruby tooling for manifest generation and validation, an
approval-gated catalog generator, and fork-safe security-lint CI. The root
catalog is intentionally empty until seed honeycombs land.

```sh
ruby script/honeycomb-manifest --check --all
ruby script/honeycomb-validate --all --json
ruby script/honeycomb-catalog --check \
  --evidence test/fixtures/listing-evidence/empty.json
ruby script/honeycomb-security-lint --help
ruby script/honeycomb-listing-approval --help
ruby test/run.rb
```

See [the package format](docs/PACKAGE_FORMAT.md) for the complete layout,
schemas, integrity model, evidence boundary, permission projection, and command
exit contract. See [Security Lint CI](docs/SECURITY_LINT_CI.md) for the
maintainer gate, analyzer/reporter trust split, required repository settings,
and SHA-bound review evidence. Hive install verbs remain owned by Hive tasks
1852/1853; this repository only publishes their future command shape.
