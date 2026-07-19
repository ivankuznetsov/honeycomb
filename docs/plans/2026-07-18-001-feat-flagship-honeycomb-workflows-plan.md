---
title: Flagship Honeycomb Workflows - Plan
type: feat
date: 2026-07-18
deepened: 2026-07-18
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Flagship Honeycomb Workflows - Plan

## Goal Capsule

Ship Architecture, Writing, and SEO Content as immutable, agent-agnostic Honeycomb packages that a released Hive can install, configure per executable step, and run end to end. The Honeycomb registry and Hive runtime are both in scope. The later removal of Hive's `architecture` and `writing` scaffold templates is gated on public-catalog proof and is a separate final migration unit.

Authority order:

1. The user's session-settled product decisions in this plan.
2. The package/catalog contracts in Honeycomb and the managed-workflow/task-pinning contracts in Hive.
3. Existing repository conventions, tests, and managed wiki guidance.
4. Implementation judgment for details that do not change product behavior.

Stop and surface a blocker only if implementation would require weakening a declared permission without disclosure, embedding agent identity in a package, changing the independent Hive `content` workflow, or bypassing Honeycomb's protected listing approvals. The execution tail owns two ordered feature PRs, their CI, the release/catalog verification chain that is reachable with current authority, and a follow-up Hive template-removal PR only after its gate is objectively satisfied.

Target repositories:

- Honeycomb registry: this repository.
- Hive runtime: the sibling Hive repository, developed on its isolated `feat/full-honeycomb-workflows` branch.

## Product Contract

### Summary

Add a workflow-scoped installation configuration layer to Hive, execute Honeycomb permissions from the exact actor descriptor instead of the catalog summary, expose immutable package tools safely, and publish three flagship packages. Keep Hive's existing templates until released-Hive public installs and complete runs prove the replacements.

### Problem Frame

Honeycomb packages are currently immutable and installable, but the registry manifest intentionally reduces all actor permissions to one coarse disclosure union. Hive then attempts to execute that union as a runtime policy and admits only one lossless subset: task-local read-only access on Claude. That makes the current path unsuitable for complete repository-aware, network-aware, or tool-bearing workflows.

Workflow descriptors also carry `agent`, `model`, and `effort`, which makes execution identity appear to be package behavior. The required product model is the opposite: a Honeycomb defines work and executable slots, while the project operator chooses the agent configuration for each slot during installation.

The SEO package adds a second missing contract. Honeycomb already hashes arbitrary nested files, but Hive does not give managed actors a stable, immutable package-root binding, so bundled analyzers and assets cannot be invoked reliably from a task work directory.

### Actors

- A1. Project operator installs or updates a Honeycomb, reviews its disclosed access, accepts suggested per-slot agent mappings, and may customize agent/model/effort before consent.
- A2. Workflow actor is an agent stage, council reviewer, or council reviser whose execution identity comes from the installed project configuration rather than `workflow.yml`.
- A3. Package maintainer authors immutable workflow behavior, instructions, and specialized tools without choosing the operator's agents.
- A4. Registry maintainer reviews high-risk releases and supplies the protected evidence required for catalog listing.
- A5. Existing project user may already have copied Hive's architecture or writing templates and must not lose that project-owned workflow when Hive later removes the scaffold source.

### Requirements

#### Installation configuration and identity

- R1. Honeycomb package descriptors must not embed `agent`, `model`, or `effort` for stages, council reviewers, or council revisers.
- R2. `hive workflow install` must enumerate every executable slot and resolve deterministic suggested defaults from an agent-agnostic slot role plus the project's existing Hive initialization choices. Interactive installation first shows one complete mapping summary with a single accept-defaults prompt, then offers explicit per-slot editing before consent; no slot is hidden from the preview or advanced editor.
- R3. Each slot mapping must support agent plus optional model and effort configuration, with interactive selection and explicit non-interactive overrides. Before snapshot identity is computed, Hive resolves effective model/effort defaults and records a canonical fingerprint of the selected agent profile's execution-relevant capabilities; task execution fails closed on profile drift until the operator installs a new mapping snapshot.
- R4. Dry-run and JSON installation output must disclose the resolved mapping and permissions before mutation; `--yes` accepts deterministic suggestions, but an unbounded/high-risk install or escalation also requires Hive's distinct explicit escalation acknowledgment.
- R5. Cancellation, invalid configuration, or failed admission must leave no selected generation, configuration snapshot, or partial commit.
- R6. Package updates must preserve compatible mappings for unchanged slots, prompt or require overrides only for new/incompatible slots, and retain old mapping snapshots while pinned tasks use them. Compatibility requires the same stable slot ID, mapping role, and package-authored `mapping_contract` revision; a revision change requires remapping or explicit reconfirmation even when permissions are unchanged.
- R7. Tasks must pin both the immutable workflow generation and the immutable installation-configuration identity so later updates or removal cannot change an in-flight task's agents.

#### Permission and runtime behavior

- R8. Hive must enforce the exact permission and optional-input authorization declared for the executing stage, reviewer, or reviser; the manifest's six-field union remains disclosure, consent, and catalog metadata only, while update escalation also compares canonical per-slot policy fingerprints.
- R9. An explicitly unbounded actor may run on any registered agent after high-risk disclosure; a bounded actor may be mapped only to a runner that can enforce its declared bound, and Hive must never silently weaken the bound.
- R10. Managed package validation must allow complete workflows, including explicitly unbounded actors, bundled instructions, current web research, and package-local tools, while continuing to reject undeclared or unhashed payloads.
- R11. Hive must expose a read-only stable package-root context for the pinned generation, preserve trusted Git executable modes through public materialization and generation placement, and resolve only manifest-hashed `100755` package tool paths through that context.
- R12. Optional package configuration may declare named environment inputs and the stable slots authorized to receive each one. Installation snapshots store only environment binding references, never values; Hive injects a resolved value only into an authorized executing slot, redacts all disclosure, labels missing optional inputs, and never requires optional SEO credentials for installation or prompt-only execution.
- R13. `gh` and `qmd` remain Hive baseline requirements and must not be modeled as per-package dependencies.

#### Flagship packages

- R14. Architecture must take a repository-aware brief through research/draft, multi-perspective council review, revision, and an `architecture.md` deliverable whose fixture-backed rubric requires repository evidence links, explicit constraints/tradeoffs, component and data-flow coverage, and visible resolution of reviewer findings.
- R15. Writing must carry the Agent Writing behavior into a journalist research step followed by writer/editor revision rounds, preserve an explicit ungrounded-result outcome, and stop at ready or a five-round cap with durable drafts and reviews. Its rubric requires source-to-claim evidence, material revision deltas, no unsupported factual claims, and an explicit terminal reason.
- R16. SEO Content must run research, intent analysis, outline, drafting, fact-checking, humanization, and optimization, producing a publishable article plus verification and optimization artifacts. Its rubric requires intent/outline/article alignment, claim-level verification status, humanization findings addressed, and measurable optimization recommendations rather than ceremonial files.
- R17. SEO Content must work without optional credentials and must enable available GA4, GSC, DataForSEO, and Ahrefs inputs when configured, clearly labeling partial data.
- R18. SEO Content may bundle a minimal audited subset of Agent SEO analyzers, scripts, rubrics, and context assets; all bundled bytes must be immutable and hash-covered.
- R19. All three packages must remain agent-agnostic and use installation mappings for every executable step, including council reviewers and revisers.

#### Publication, proof, and migration

- R20. Hive support must ship and be released before a flagship declares its minimum compatible Hive version or enters the public catalog.
- R21. Each flagship release must follow Honeycomb's immutable two-commit provenance flow and pass manifest, validation, compatibility, security-lint, and catalog tests.
- R22. Public acceptance must install each package from canonical catalog bytes with released Hive, create a pinned task, complete the deterministic CI workflow, and prove its final artifact against the package rubric. Before U9, evidence must also include one complete live run per flagship through a supported registered agent profile plus a live or provider-contract smoke for every SEO integration the public package claims as enabled.
- R23. Hive's bundled `architecture` and `writing` scaffold sources must be removed only after all three packages are listed, the public acceptance chain succeeds, and replacement-parity checks prove the Honeycombs preserve or improve the documented user-visible outcomes of the old scaffolds. Already-copied project workflows must remain runnable, while the familiar discovery names remain visible as catalog-backed installation entries.
- R24. Hive Bench stays built in, and the distinct Hive `content` workflow is not removed or implicitly migrated by this work.

### Key Flows

- F1. Install: fetch and validate immutable package -> enumerate slots -> derive suggestions -> collect or apply mapping overrides -> validate each selected runner against that slot -> disclose permissions and resolved configuration -> obtain consent -> atomically place generation/configuration and activate the lock.
- F2. Create/run: resolve selected generation plus configuration -> pin both identities in task metadata -> overlay the mapping in memory -> expose pinned package context -> execute each actor with its exact declared access -> produce the terminal deliverable.
- F3. Update: fetch candidate -> diff behavior/security/slots -> preserve compatible mappings -> resolve additions or incompatibilities -> consent -> atomically activate candidate generation and configuration while retaining old pinned pairs.
- F4. Publish: commit behavior source -> generate manifest referencing preserved source revision -> obtain protected lint and required independent approvals -> generate canonical catalog -> publish exact catalog/site snapshot.
- F5. Migrate discovery: after released-Hive public runs and replacement-parity checks succeed, remove only Hive's bundled architecture/writing template sources, retain their familiar discovery names as catalog-backed entries, and route selection/documentation to `hive workflow install honeycomb/<name>`.

### Acceptance Examples

- AE1. Interactive Architecture install suggests mappings for draft, each reviewer, revise, and final; customizing one reviewer persists a project configuration without adding agent identity to the package descriptor.
- AE2. `install --dry-run --json` reports the same permissions and resolved mapping that an applied install would use; an invalid mapping and an interactive cancellation both leave the project byte-for-byte unchanged.
- AE3. A task created before an update keeps its old generation and mapping, while a new task uses the updated generation and preserved-plus-new mapping; changing a slot's mapping role/contract revision or the selected profile fingerprint forces reconfirmation instead of silent reuse.
- AE4. Architecture reads repository context, reaches council quorum through revision when needed, and finishes with non-empty `architecture.md`.
- AE5. Writing produces a grounded brief, versioned draft/review rounds, and a ready draft or explicit cap result; an ungroundable investigation produces an honest stopped outcome rather than fabricated prose.
- AE6. SEO runs prompt-only with no optional credentials, labels a partially configured data-source run, and can invoke a manifest-hashed bundled analyzer from its pinned package root.
- AE7. Mapping an unbounded SEO step to Codex is admitted with high-risk disclosure; mapping a bounded step to a profile that cannot enforce it fails before project mutation.
- AE8. A fresh installation from the public catalog with released Hive completes each flagship and records catalog commit, package digest, configuration digest, slot mappings, and final artifact.
- AE9. Removing Hive's architecture/writing scaffold sources does not alter an existing copied descriptor, Bench, or the built-in `content` workflow.
- AE10. After scaffold-source removal, `architecture` and `writing` remain discoverable; selecting either starts the matching Honeycomb install flow, and parity fixtures prove the new final artifacts retain the old workflows' documented repository-analysis and writing outcomes.

### Success Criteria

- Hive's managed execution no longer reconstructs policy from the catalog permission union.
- Every executable flagship slot is configured at install time and pinned for task lifetime.
- The three packages pass local registry validation and deterministic cross-repo execution tests.
- The public catalog/released-Hive chain is proven before template removal begins.
- No optional SEO provider is required for the default path, and no configured credential is exposed outside its declared package input.

### Scope Boundaries

In scope:

- Hive managed-workflow mapping, pinning, exact actor permission admission, and package-runtime context.
- Honeycomb validation/format documentation needed to support agent-agnostic packages and specialized runtime metadata.
- The three flagship packages and deterministic full-workflow tests.
- Ordered release/catalog verification and the gated template-removal follow-up.

#### Deferred to Follow-Up Work

- Replacing or migrating Hive's built-in `content` workflow.
- Moving Bench out of Hive.
- Reviewer Panel and Incident Postmortem Honeycombs.
- A general end-user `hive workflow publish` overhaul; the first flagships may be authored directly in the registry using its native package format.
- Automatic credential acquisition or OAuth setup for SEO providers.

### Dependencies

- A released Hive version containing the prerequisite runtime contract.
- The Agent Writing and Agent SEO source material at immutable upstream revisions.
- Honeycomb's protected lint evidence and, for high-risk packages, two distinct eligible maintainer approvals.
- Canonical catalog publication and the Cloudflare Pages site snapshot serving the same catalog commit.

## Planning Contract

### Key Technical Decisions

- KTD1. Package behavior and execution identity are separate. Stable slot IDs are `stages.<stage>`, `stages.<stage>.reviewers.<reviewer>`, and `stages.<stage>.revise`; an installation configuration overlays agent/model/effort onto a parsed immutable workflow. (session-settled: user-directed — chosen over embedding agents in workflow packages: the operator, not the package author, owns agent choice.)
- KTD2. Installation configurations are immutable digest-addressed snapshots retained beside package generations. Canonical identity includes stable slot mappings, resolved effective model/effort, and execution-relevant agent-profile fingerprints. The selected lock points to both package and configuration digests, task metadata pins both, and runtime fails closed when a registered profile no longer matches the pinned fingerprint, preventing update/removal or mutable defaults from changing an existing task silently.
- KTD3. Exact descriptor permission blocks are executable policy; the manifest union is disclosure-only. This removes the lossy union-to-policy reconstruction without weakening any declared actor scope.
- KTD4. Agent choice is compatibility-aware rather than Claude-hardcoded. Unbounded scopes are portable because the absence of a bound is explicit; bounded scopes expose only runners that can enforce them. This satisfies configurable agents without silently claiming parity that a profile lacks.
- KTD5. Suggested mappings use an agent-agnostic `mapping_role` plus package-authored `mapping_contract` revision declared on executable slots. Roles are `planning`, `development`, or `reviewer`: `planning` maps to the project's planning choice, `development` maps to its development choice, council reviewers use `reviewer` and cycle the configured review agents, and revisers declare planning or development; explicit overrides always win. Roles express the work shape, never a provider, while a contract revision gives maintainers an explicit way to invalidate stale semantic mappings.
- KTD6. A strict `x-hive` manifest extension describes optional environment names, their authorized stable slot IDs, and package-local executable paths. Honeycomb validates JSON shape, slot references, and path containment; Hive validates semantics, verifies every path and trusted `100755` mode against the manifest inventory, exposes the pinned package root in prompt context, and passes only the current slot's authorized configured inputs.
- KTD11. Optional input bindings are immutable configuration metadata but secret values are live. A snapshot records only `input name -> environment variable name`; explicit install/update bindings win, compatible prior bindings are preserved, a present same-name environment variable is the suggestion, and otherwise the optional input remains unbound. Runtime resolves the pinned reference from the current process environment only for an authorized slot, so rotation does not rewrite tasks and revocation is an environment removal; values never enter committed Hive state, task metadata, previews, or logs.
- KTD12. Update escalation is actor-aware. Hive fingerprints each slot's exact tools, paths, unbounded state, and authorized input names, diffs fingerprints across versions, and requires explicit escalation consent for any gain or newly dangerous combination even when the package-wide union is unchanged.
- KTD7. `gh` and `qmd` remain baseline Hive dependencies, not Honeycomb dependency declarations. (session-settled: user-directed — chosen over package-specific dependency checks: Hive itself owns those tools.)
- KTD8. SEO bundles only the analyzers and assets required by the flagship path, not the entire Agent SEO plugin tree or its vendor bundle. (session-settled: user-approved — chosen over prompt-only SEO or a full plugin mirror: specialized Honeycombs may carry their own tools while keeping the release auditable.)
- KTD9. Writing uses Hive's existing council/revise loop and a package-defined strict reviewer protocol. `start over` is carried as a required-edit directive that tells the reviser to replace the draft, while ready/changes-requested remains the engine verdict contract.
- KTD10. Hive runtime ships first; registry packages declare the released minimum; catalog listing/public E2E follows; scaffold removal is last. (session-settled: user-directed — chosen over deleting templates in the prerequisite change: replacements must be proven in Honeycombs first.)

### Assumptions

- A package may explicitly choose unbounded permissions for an actor when full repository, network, or shell access is required. This is not a weakened bounded policy; it is high-risk behavior that must be visible in the manifest and listing gate.
- The first three packages can use existing linear stages and council revision without a new general branching DSL. An ungrounded Writing result is represented as an explicit terminal deliverable path through package instructions rather than a silent skip.
- Model/effort values are optional. Unsupported effort on a selected profile is reported in the preview and omitted only with explicit operator acceptance, never silently transformed.
- Optional SEO data values are already available through project configuration or the environment; this work declares and passes them but does not acquire credentials.
- Deterministic agents and provider fakes are CI infrastructure, not substitutes for the U10 production-interoperability evidence required before scaffold removal.
- Registry maintainers will supply listing approvals after code review. Until then, CI-green package PRs are shippable code but not publicly listed releases.

### High-Level Technical Design

```text
Honeycomb immutable package
  workflow.yml -------- exact per-actor access + stable actor names
  manifest.yml -------- coarse union + hashes + x-hive runtime declarations
  instructions/tools -- immutable, manifest-hashed payload
          |
          v
Hive install/update
  validate package -> enumerate slots -> resolve operator mapping
  -> validate actor/scope/profile compatibility -> disclose/consent
  -> store package generation + configuration snapshot -> activate lock
          |
          v
Hive task creation/runtime
  pin package digest + configuration digest
  -> load exact generation -> overlay identities in memory
  -> expose pinned package context -> execute actor's own permission block
          |
          v
Public proof gate
  released Hive -> canonical catalog -> complete flagship runs
  -> remove Hive architecture/writing scaffold sources
```

The package and installation configuration have independent identities. A behavior update can reuse unchanged slot mappings, but it produces a new configuration snapshot bound to the candidate generation. Old snapshots remain reachable exactly while task metadata references them.

### System-Wide Impact

- Persistence: selected locks and task metadata gain a configuration digest covering agent mappings and optional-input references, never secret values. Cleanup must retain configuration snapshots referenced by active selections or tasks and remove only unreferenced pairs.
- Loading and cache behavior: both selected-workflow loading and pinned-task loading must apply the correct configuration overlay, workflow loader caches must include the configuration digest in their fingerprint, and execution must reject a drifted agent-profile fingerprint rather than re-resolving mutable defaults.
- CLI/API: install and update human output and JSON schemas gain slot mapping, compatibility, and optional-input disclosure. Noninteractive mutation still requires ordinary consent semantics.
- Agent parity: stage, reviewer, and revise launch paths must all consume the overlaid identity and exact actor permission. Tests must prevent a stage-only implementation that forgets council actors.
- Security: package-root exposure is read-only context, executable paths must be manifest-hashed, and optional values are allowlisted by name and authorized slot. The high-risk catalog approval gate remains independent of runtime admission.
- Release operations: Honeycomb packages cannot truthfully set `hive_min_version` until the prerequisite Hive version exists. Public proof must bind the Hive release, catalog commit, site snapshot, and package/configuration digests.

### Risks and Mitigations

- Silent policy weakening across agents: fail admission for bounded scopes unsupported by the selected profile; use explicit unbounded permissions where portability is required.
- Mapping drift on update/removal: digest-address configuration, pin it in tasks, and include it in retention/cleanup logic.
- Runner/profile drift: snapshot resolved model/effort and an execution-relevant profile fingerprint; fail closed and require a new operator-confirmed snapshot after profile changes.
- Semantic slot drift: preserve mappings only when slot ID, mapping role, and package-authored mapping-contract revision remain compatible.
- Partial installation state: extend the existing managed transaction so generation, configuration, lock, and state commit roll back together on errors and interrupts.
- Package tool escape or tampering: accept normalized relative paths only, require manifest membership and executable regular files, and resolve from the verified pinned generation.
- Credential leakage: declare names, never values, in package metadata; persist only environment references, resolve values at spawn, and redact previews/logs and missing-input diagnostics.
- Cross-slot credential exposure: bind every optional input to explicit stable slots, inject it only for the current actor, and test that sibling stages/reviewers/revisers cannot observe it.
- Hidden policy redistribution: compare actor-level permission/input fingerprints on update and require escalation for a slot-level gain even when the package union is unchanged.
- Indirect prompt injection: treat web pages and provider responses as untrusted data, wrap them separately from executable instructions, and do not let a research/data stage combine raw external content with unbounded shell or repository-write authority.
- Source/plugin drift: pin Agent Plugins source revisions and test required source-path byte identity or documented adaptations.
- Listing delay: keep protected approval as an explicit external gate and do not claim public availability from code CI alone.
- Premature or regressive migration: automate public-proof and outcome-parity artifacts, preserve catalog-backed discovery aliases, and make bundled-source removal depend on both gates rather than release intent.

### Sequencing

1. Land Hive's mapping/runtime contract.
2. Release that exact Hive prerequisite from green CI.
3. Land the Honeycomb contract validation and behavior-bearing package sources.
4. Generate immutable manifests against the released Hive minimum and obtain listing evidence/approvals.
5. Publish catalog/site bytes and run public released-Hive acceptance.
6. Remove Hive's two scaffold templates in a separate gated change.

## Implementation Units

### U1. Add immutable managed-workflow configurations in Hive

Goal: represent, store, pin, load, retain, and clean up per-slot agent/model/effort mappings independently from package behavior.

Requirements: R1-R7.

Files:

- Hive: `lib/hive/workflow_package/managed_store.rb`
- Hive: new `lib/hive/workflow_package/configuration.rb`
- Hive: `lib/hive/task_meta.rb`, `lib/hive/task.rb`, `lib/hive/commands/new.rb`
- Hive: `lib/hive/workflows/loader.rb`, `lib/hive/workflows/project.rb`
- Hive: `test/unit/workflow_package/managed_store_test.rb`, `test/unit/task_meta_test.rb`, `test/unit/task_test.rb`

Approach:

- Define canonical configuration bytes with stable slot IDs, mapping roles/contracts, resolved effective model/effort, execution-relevant profile fingerprints, and a SHA-256 identity.
- Store verified snapshots outside immutable package payload directories and reference the digest from lock schema v2.
- Apply mappings as an in-memory copy of stages/reviewers/revisers after parsing, leaving package bytes unchanged.
- Extend task pins, stable loader reads, cleanup, and transaction rollback to cover configuration identity.

Test scenarios:

- A selected workflow and a created task resolve the same mapping digest and effective actors.
- Updating the selected mapping does not alter a previously pinned task.
- Removal retains a pinned configuration and cleanup removes it after the final reference disappears.
- Malformed mapping, unknown slot, mismatched generation, partial provenance, and tampered digest fail closed.
- Changing a selected profile's executable/capability fingerprint after task creation fails closed rather than silently changing the task's effective runner; installing a new confirmed snapshot restores execution.

Verification: targeted store/task/loader tests prove byte-stable identity, pinning, retention, and rollback.

Dependencies: none.

### U2. Execute exact actor permissions and expose verified package context in Hive

Goal: replace catalog-union runtime reconstruction with per-actor descriptor policy and make hashed specialized tools usable.

Requirements: R8-R13.

Files:

- Hive: `lib/hive/workflow_package/runtime_policy.rb`, `lib/hive/workflow_package/validator.rb`, `lib/hive/workflow_package/registry_manifest.rb`
- Hive: `lib/hive/workflow_package/registry_client.rb`, `lib/hive/workflow_package/managed_store.rb`
- Hive: `lib/hive/stages/base.rb`, `lib/hive/stages/agent.rb`
- Hive: `lib/hive/stages/council/reviewer.rb`, `lib/hive/stages/council/revise.rb`
- Hive: `lib/hive/permission_scope.rb`, relevant agent profile adapters
- Hive: `test/unit/workflow_package/runtime_policy_test.rb`, `test/unit/workflow_package/validator_test.rb`
- Hive: `test/unit/stages/agent_test.rb`, council stage tests, `test/unit/spawn_agent_test.rb`

Approach:

- Admit the effective configured workflow by enumerating each executable actor and resolving that actor's permission block against its mapped profile.
- Remove registry permission-union compilation from spawn paths; retain the union in disclosure and escalation comparisons.
- Permit explicit unbounded managed actors and continue rejecting absent permissions.
- Parse strict `x-hive` runtime metadata, carry trusted `100644`/`100755` Git tree modes through registry materialization and managed-generation placement, require declared tools to originate as `100755`, and inject a package-context preamble plus declared optional environment values at every managed actor launch.

Test scenarios:

- Different stage/reviewer/revise scopes reach their own spawn rather than one shared union.
- An unbounded actor runs on Claude and Codex; an unsupported bounded mapping fails before mutation.
- Web research and package-local executable access are no longer always denied.
- Traversal, unlisted executable, symlink, non-executable source mode, mode loss during public install, undeclared environment name, and secret-value logging are rejected.

Verification: actor-level launch tests and runtime-policy tests prove exact scope selection and package-root containment.

Dependencies: U1.

### U3. Add install/update mapping UX and machine contracts in Hive

Goal: collect suggested per-slot configuration before consent and preserve it safely across updates.

Requirements: R2-R7, R9, R12.

Files:

- Hive: `lib/hive/commands/workflow/install.rb`, `lib/hive/commands/workflow/update.rb`, `lib/hive/commands/workflow/base.rb`
- Hive: new workflow-install prompt/configuration helper under `lib/hive/commands/workflow/`
- Hive: CLI option dispatch for repeatable mapping overrides
- Hive: `lib/hive.rb`, `schemas/hive-workflow-install.v2.json`, `schemas/hive-workflow-update.v2.json`
- Hive: `test/unit/commands/workflow_lifecycle_test.rb`, `test/unit/commands/workflow_update_test.rb`
- Hive: `test/unit/workflow_lifecycle_schema_test.rb`

Approach:

- Reuse the `hive init` name/index menu behavior and registered-agent order.
- Resolve role-based suggestions, explicit mapping overrides, and environment-reference bindings before dry-run/consent; include compatibility, binding state, and unsupported optional identity fields in preview without values.
- Reuse Hive's separate escalation consent for any install/update that introduces an unbounded actor; plain `--yes` is insufficient for that privilege increase.
- Reconcile candidate slots by stable ID, mapping role, and `mapping_contract` revision during update, preserving compatible values and resolving or explicitly reconfirming semantic incompatibilities; diff canonical per-slot policy fingerprints rather than relying on the package union for escalation.
- Activate package generation, configuration snapshot, and lock in one rollback-capable state commit.

Test scenarios:

- Interactive defaults, name/index customization, per-slot model/effort, cancellation, and EOF behave deterministically.
- JSON/non-TTY dry-run reports mapping; `--yes` applies suggestions; repeated overrides select exact slots.
- High-risk/unbounded mutation requires both ordinary consent and explicit escalation consent, including an update that keeps the same slot ID but broadens its permissions.
- Moving network, shell, write, or input authorization onto one slot triggers escalation even when the old and new package-wide unions are identical.
- Invalid agent/model/effort and incompatible permission/profile combinations fail with no writes.
- Explicit input references override preserved bindings; same-name environment variables are suggested; unbound or unavailable optional inputs remain labeled and do not block prompt-only execution.
- Update adds, removes, and renames slots without corrupting the previous selection or old-task pins.
- Keeping a slot ID while changing its mapping role/contract revision requires explicit reconfirmation, and agent-profile fingerprint drift cannot be accepted implicitly.

Verification: command and schema tests prove human and JSON contracts plus zero-write failure semantics.

Dependencies: U1, U2.

### U4. Prove the Hive contract through managed lifecycle integration

Goal: exercise install, mapping, task pinning, complete execution, update, and removal through the real Hive command/runtime seams.

Requirements: R4-R12, R19.

Files:

- Hive: `test/integration/honeycomb_workflow_lifecycle_test.rb`
- Hive: new deterministic flagship managed-workflow integration fixtures/tests
- Hive: fake-agent and default-deny `gh` E2E fixtures where needed
- Hive: `wiki/commands/workflow.md`, `wiki/modules/workflows.md`, `wiki/modules/agent_profile.md`, `wiki/gaps.md`
- Hive: new `wiki/log.d/<timestamp>-full-honeycomb-runtime.md`

Approach:

- Extend the immutable local-catalog fixture to include multiple actor slots, a package-local tool, optional inputs, and a version update.
- Drive real task creation and generic stage/council execution with deterministic agents that produce required artifacts and verdicts.
- Record the exact provenance/configuration fields asserted by the public proof flow.

Test scenarios:

- Install -> customize mapping -> create -> run -> final deliverable succeeds.
- Update with a new slot preserves and runs an old pinned task, while a new task uses the new pair.
- Removal retains both identities for the old task and deletes only unreferenced candidate state.
- Commit failure and interrupt roll back generation, configuration, lock, and staging residue.

Verification: Hive targeted integration tests and the repository's full CI gate pass on the exact branch head.

Dependencies: U1-U3.

### U5. Extend Honeycomb validation for agent-agnostic and specialized packages

Goal: make the registry reject identity-bearing packages and validate specialized runtime declarations without changing the coarse permission projection.

Requirements: R1, R8, R10-R13, R18-R19.

Files:

- Honeycomb: `lib/honeycomb_registry/hive_compatibility.rb`, `lib/honeycomb_registry/validator.rb`
- Honeycomb: `lib/honeycomb_registry/package.rb`, `lib/honeycomb_registry/security_lint.rb` or its current scanner components
- Honeycomb: `docs/PACKAGE_FORMAT.md`, `wiki/package-catalog-contract.md`, `wiki/security-review-contract.md`, `wiki/gaps.md`
- Honeycomb: `test/hive_compatibility_test.rb`, `test/validator_test.rb`, `test/permissions_test.rb`, `test/security_lint_test.rb`
- Honeycomb: new `wiki/log.d/<timestamp>-flagship-runtime-contract.md`

Approach:

- Scan all actor locations and reject `agent`, `model`, and `effort` for registry packages while requiring valid agent-agnostic `mapping_role` metadata on managed executable slots and leaving Hive's local-authored descriptor format unchanged.
- Validate the `x-hive` extension's closed keys, normalized relative tool paths, declared environment-name syntax, authorized stable-slot references, and package inventory membership.
- Extend security lint to inspect behavior-bearing bundled scripts/assets and attribute their shell/network/secret implications.

Test scenarios:

- Identity fields fail at every actor location with attributed diagnostics.
- Valid optional environment and tool declarations survive canonical manifest generation.
- Traversal, missing/unhashed paths, executable script surprises, and unknown extension keys fail.
- Input authorization rejects unknown/terminal slots, and tests prove only the authorized actor receives a configured secret canary.
- Permission union still includes every active stage/reviewer/reviser and remains deterministic.

Verification: Honeycomb unit tests and manifest/validator checks pass for valid and adversarial fixtures.

Dependencies: U2 contract shape.

### U6. Author the three flagship Honeycomb package sources

Goal: create complete immutable Architecture, Writing, and SEO Content behavior with no embedded agent identities.

Requirements: R14-R19, R21.

Files:

- Honeycomb: `packages/architecture/1.0.0/**`
- Honeycomb: `packages/writing/1.0.0/**`
- Honeycomb: `packages/seo-content/1.0.0/**`
- Honeycomb: package-specific tests under `test/`

Approach:

- Architecture adapts Hive's existing architecture template, adds repository research, keeps two independent reviewers plus reviser, and produces a terminal architecture deliverable.
- Writing adapts Agent Writing at its pinned source revision into journalist, writer, adversarial editor council, and final delivery instructions, using five-round consensus revision and explicit ungrounded/cap outcomes.
- SEO Content adapts Agent SEO at its pinned source revision into the agreed research -> intent -> outline -> draft -> fact-check -> humanize -> optimize flow, declares optional provider inputs, and bundles only required analyzer/context files.
- Start package authoring as soon as U5 defines the contract. Preserve behavior-bearing source commits independently, but gate final canonical manifest generation and each `hive_min_version` on the released U8 version and source identity.

Test scenarios:

- Descriptor shapes, slot sets, actor permissions, deliverables, reviewer protocol, round caps, and optional-input declarations match the Product Contract.
- Source-provenance paths are byte-identical where copied; documented adaptations are covered by behavior tests.
- Every regular payload file is manifest-hashed and tampering any flagship fails validation.

Verification: package-focused tests plus `honeycomb-manifest --check` and `honeycomb-validate` pass for each immutable version.

Dependencies: U5 for package authoring; U8 is a hard gate only for final canonical manifest generation and compatibility metadata.

### U7. Add cross-repo flagship execution tests and registry documentation

Goal: prove each package's full behavior against the compatible Hive runtime before catalog submission.

Requirements: R14-R19, R21.

Files:

- Honeycomb: `test/end_to_end_test.rb` or focused flagship E2E test files
- Honeycomb: test support for invoking the compatible Hive checkout/release with deterministic agents
- Honeycomb: `README.md`, `docs/PACKAGE_FORMAT.md`, `wiki/index.md`, `wiki/gaps.md`
- Honeycomb: new `wiki/log.d/<timestamp>-flagship-workflows.md`

Approach:

- Materialize a test catalog containing the real package bytes and invoke Hive's real install/create/run path.
- Assert mapping/configuration provenance and fixture-backed package quality rubrics rather than only parser success or non-empty artifacts.
- Keep provider APIs hermetic: fake current research/data responses and separately test missing/partial optional configuration.

Test scenarios:

- Architecture reaches a revised council-approved `architecture.md`.
- Writing covers ready-after-revision, ungrounded, and five-round-cap outcomes.
- SEO covers prompt-only, partial data, and package-tool-assisted runs and produces article/fact-check/optimization artifacts.
- Architecture evidence linkage/coverage/reviewer-resolution, Writing claim grounding/revision deltas/terminal reason, and SEO alignment/verification/humanization/optimization rubric assertions all pass against deterministic fixtures.

Verification: all Honeycomb tests, validation, compatibility, catalog generation, and security lint pass on exact head.

Dependencies: U4-U6, U8.

### U8. Release the Hive prerequisite

Goal: publish the exact Hive runtime and mapping contract that final Honeycomb manifests require.

Requirements: R20.

Files:

- Hive: version/changelog/release files required by `docs/RELEASING.md`
- Hive: release verification evidence required by the repository's release process

Approach:

- Merge the U1-U4 prerequisite from exact-head green CI.
- Prepare and publish the next Hive version through the repository-native release process.
- Record the release tag, source SHA, and artifact digest for Honeycomb compatibility tests and final `hive_min_version` fields.

Test scenarios:

- The release artifact reports the expected version and source revision.
- The released binary passes the managed-workflow contract tests used by Honeycomb compatibility validation.
- A pre-release/older Hive still rejects a package requiring this version without writes.

Verification: release validation, published artifact checks, and exact-tag CI are green before U6 generates final manifests.

Dependencies: U4.

### U10. List, publish, and run the public proof chain

Goal: turn CI-green cross-repo code into released Hive support and publicly installable canonical Honeycombs.

Requirements: R20-R22.

Files:

- Honeycomb: final generated manifests, normalized listing evidence, approvals, and catalog/site publication inputs
- Honeycomb: durable canary/proof documentation under the existing wiki contract

Approach:

- Confirm each immutable manifest already declares the U8 released minimum, then obtain the required protected evidence and independent high-risk approvals.
- Verify canonical catalog bytes and Cloudflare Pages snapshot identity, then use the released Hive binary for fresh public installs, deterministic reproducibility runs, and one complete live run of each flagship through a supported registered agent profile.
- Run a live smoke when credentials are available, or a provider-maintained contract smoke otherwise, for GA4, GSC, DataForSEO, and Ahrefs before claiming each integration enabled; missing external credentials block that integration claim and U9, not prompt-only package operation.
- Record Hive version, catalog/site commit, package digest, configuration digest, profile fingerprint, effective model/effort, mappings, rubric results, provider-smoke evidence, and final artifacts.

Test scenarios:

- A version older than the declared minimum rejects each package without writes.
- Exact released Hive installs and runs each public entry successfully.
- Supported live agent profiles complete each flagship, package-specific rubrics pass, and every claimed SEO provider integration has live or contract-smoke evidence.
- Catalog and site serve the reviewed immutable package version and approval identity.

Verification: release checks, protected catalog checks, site snapshot verification, and public canary evidence are green. If approval authority is unavailable, stop with the exact external gate rather than claiming listing.

Dependencies: U7, U8, maintainer approvals and catalog/site publication authority.

### U9. Remove superseded Hive scaffold sources after proof

Goal: make Honeycomb installation the source for new Architecture/Writing workflows without breaking existing project-owned copies or unrelated built-ins.

Requirements: R23-R24.

Files:

- Hive: `templates/workflows/architecture/**`, `templates/workflows/writing/**`
- Hive: workflow-template discovery/help/docs and their tests
- Hive: `wiki/commands/workflow.md`, `wiki/modules/workflows.md`, `wiki/gaps.md`
- Hive: new `wiki/log.d/<timestamp>-externalize-flagship-templates.md`

Approach:

- Require the durable U10 public proof before deletion.
- Remove only the two bundled scaffold sources; preserve their discovery/help entries as catalog-backed aliases that launch the corresponding Honeycomb installation flow.
- Run explicit parity fixtures against the old scaffold outcomes before deletion, covering repository-aware architecture analysis and the documented research/draft/edit writing result.
- Preserve loading of existing copied descriptors and leave Bench and `content` unchanged.

Test scenarios:

- Template discovery still offers architecture/writing as catalog-backed entries, and selecting one points to or launches the matching Honeycomb install flow without copying a bundled descriptor.
- Architecture and Writing parity fixtures prove the Honeycomb outputs preserve or improve the old scaffolds' documented user-visible outcomes.
- A fixture containing an already-copied architecture or writing descriptor still loads and runs.
- Bench installation and `content` workflow tests remain unchanged and green.

Verification: targeted template/workflow tests and full Hive CI pass; the PR links the U10 public proof.

Dependencies: U10 hard gate.

## Verification Contract

Hive prerequisite gates:

- Run targeted workflow-package, task metadata, loader, stage/council, command, schema, and Honeycomb integration tests through the repository's Bundler test entrypoint.
- Run `bin/ci` on the exact Hive branch head.
- Watch GitHub checks on the exact pushed head to green before treating the prerequisite as releasable.

Honeycomb package gates:

- `ruby test/run.rb`
- `ruby script/honeycomb-manifest --check --all`
- `ruby script/honeycomb-validate --all --json --require-hive`
- Generate the catalog through the repository's protected evidence path and run security lint for every changed immutable package root.
- Confirm `git diff --check` in both repositories.

Cross-repo behavioral gates:

- Install, map, create, and fully run Architecture, Writing, and SEO Content with deterministic fake agents using the real Hive binary path.
- Exercise at least one customized reviewer mapping, a package update with old-task retention, optional SEO inputs absent and partial, and one manifest-hashed SEO tool.
- Validate install/update JSON payloads against their new schemas.

Public release gates:

- Verify the released Hive version and digest.
- Verify canonical catalog commit equals the site-served snapshot.
- Install all three by public `honeycomb/<name>` resolution and record package/configuration provenance plus final artifacts.
- Complete one run per flagship through a supported registered agent profile and record the pinned profile fingerprint/effective model/effort.
- Require package-specific quality rubrics and live-or-contract smoke evidence for every SEO provider integration claimed enabled before the U9 migration gate opens.
- Do not begin U9 until this evidence exists for all three.

## Definition of Done

- U1-U4 are merged and documented in Hive with exact-head CI green, and U8 publishes their verified release.
- U5-U7 are merged in Honeycomb with canonical immutable manifests and all local/cross-repo gates green.
- U10 either completes with listed packages and public proof, or reports the precise external approval/catalog gate without misrepresenting public availability.
- U9 is merged only if U10 completed; otherwise it remains unstarted and Hive's templates stay available.
- Architecture, Writing, and SEO Content contain no package-authored agent/model/effort identity.
- Existing tasks retain both workflow and mapping semantics across update/removal.
- Bench and Hive `content` remain in place.
- Wiki pages and log fragments are current in both changed repositories, and uncertainty is recorded in `wiki/gaps.md`.
- Dead-end experiments, temporary package state, generated test residue, and unused compatibility code are removed from both diffs.
