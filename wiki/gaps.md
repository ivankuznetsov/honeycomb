# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Command surface | `hive workflow install honeycomb/<name>` is documented but not implemented here. | README says install verbs land with Hive tasks 1852/1853, which are outside this repository. |
| Scoped-rule release | Hive PR #769 defines the portable qualified-file-rule contract after the v0.4.2 release. | Docs Sync must require the first release containing that PR (expected v0.4.3); strict Hive compatibility remains blocked until that release exists. |
| Seed listing approvals | Listing evidence must bind the final package release and PR head, and the PR author cannot issue their own eligible review. | Add another eligible maintainer; Docs Sync needs one current approval and high-risk Bench needs two distinct current approvals. |
| Bench Verified debut | The frozen policy requires two prior clean listed publisher releases plus genuine keyless signature and Actions attestation evidence, but the seed catalog has no prior releases. | Supply qualifying history and release proof, or explicitly amend the seed requirement/trust policy; do not fabricate evidence or silently demote Bench. |
| Catalog surface | Root `catalog.json` is generated, but `hive.sh/honeycombs` has no route, handler, or static renderer here. | Static site work consumes `honeycomb-catalog/v2`; task 1851 seeds real entries. |
| Approval rollout | The trusted issuer, immutable GitHub storage paths, and offline exporter are shipped, but the protected environment/evidence branch cannot be created or canaried from this feature pull request. | After merge, protect `honeycomb-listing-approval` and `honeycomb-evidence`, then exercise an eligible and ineligible dispatch. |
| Security-lint rollout | Static/unit coverage is shipped, but effective fork permissions and `workflow_run` writes cannot be canaried until both workflows are on the default branch. | After merge, run the documented fork canary and require `honeycomb/security-lint` in branch protection. |
| Lifecycle rollout | Durable state preservation and the protected normalized-evidence path are defined, but emergency transitions have not been canaried on the live repository. | Exercise soft-hide, yank, revoke, and relist against `honeycomb-evidence:normalized/listing-evidence-v1.json` without losing history. |
| Community-review rollout | Trusted-base record/identity validation is shipped but cannot run until its workflow is present on the default branch. | After merge, canary an exact-author review and an impersonated filename from a fork. |
