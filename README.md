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
contract and offline Ruby tooling for manifest generation, validation, and
approval-gated catalog generation. The root catalog is intentionally empty
until seed honeycombs land.

```sh
ruby script/honeycomb-manifest --check --all
ruby script/honeycomb-validate --all --json
ruby script/honeycomb-catalog --check \
  --evidence test/fixtures/listing-evidence/empty.json
ruby test/run.rb
```

See [the package format](docs/PACKAGE_FORMAT.md) for the complete layout,
schemas, integrity model, evidence boundary, permission projection, and command
exit contract. Hive install verbs remain owned by Hive tasks 1852/1853; this
repository only publishes their future command shape.
