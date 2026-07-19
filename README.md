# honeycomb

A library of **honeycombs** — publishable workflows for
[hive](https://github.com/ivankuznetsov/hive). Publish yours, install others',
every listing security-reviewed. A honeycomb's stage instructions are agent
prompts that may request powerful repository, network, or tool access, so the
review gate is the product.

- Catalog: **hivecli.sh/honeycombs**
- Install a listed release: `hive workflow install honeycomb/<name>`
- A *honeycomb* = descriptor (`workflow.yml`) + stage instructions + manifest
  (version, author, permissions summary, sha256 integrity)

The repository now ships the independent `honeycomb-manifest/v1` package
contract, offline Ruby tooling for manifest generation and validation, an
approval-gated catalog generator, and fork-safe security-lint CI. The root
catalog contains the listed `task-inspect` production canary. Its contract keeps
Community/Verified history, permission risk, lifecycle state, verification, and
public advisories independent; only listed versions participate in discovery.
Strict community-review validation runs as trusted base code and binds review
identity to the canonical package and catalog without executing submitted code.

The repository also contains the behavior sources for three flagship 1.0.1
packages:

- `architecture` — repository research, proposal, council review, revision,
  and an implementation-ready architecture record;
- `writing` — journalist research and an adversarial writer/editor loop with
  honest ungrounded and round-cap outcomes;
- `seo-content` — research, intent, outline, draft, fact-check, humanization,
  and optimization, including an immutable package-local analyzer.

Package presence is not catalog listing. The three immutable manifests require
the released Hive 0.6.0 runtime; until each package has protected lint evidence
plus the required independent approvals, it is not discoverable or publicly
installable from `honeycomb/<name>`.

```sh
ruby script/honeycomb-manifest --check --all
ruby script/honeycomb-validate --all --json
ruby script/honeycomb-catalog --check \
  --evidence test/fixtures/listing-evidence/empty.json
ruby script/honeycomb-security-lint --help
ruby script/honeycomb-listing-approval --help
ruby script/honeycomb-reviews
ruby test/run.rb

# Focused source-to-Hive acceptance against a compatible checkout
HONEYCOMB_HIVE_SOURCE=/path/to/hive \
  RUBYLIB=/path/to/hive/lib \
  ruby -Itest test/flagship_hive_execution_test.rb
```

See [the package format](docs/PACKAGE_FORMAT.md) for the complete layout,
schemas, integrity model, evidence boundary, permission projection, and command
exit contract. See [Security Lint CI](docs/SECURITY_LINT_CI.md) for the
maintainer gate, analyzer/reporter trust split, required repository settings,
and SHA-bound review evidence. Hive owns install-time agent mappings, immutable
configuration pins, and package runtime context; this repository owns the
reviewed package bytes and catalog eligibility.
