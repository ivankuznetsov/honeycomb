# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Command surface | `hive workflow install honeycomb/<name>` is documented but not implemented here. | README says install verbs land with Hive tasks 1852/1853, which are outside this repository. |
| Catalog surface | Root `catalog.json` is generated, but `hive.sh/honeycombs` has no route, handler, or static renderer here. | Static site work consumes `honeycomb-catalog/v1`; task 1851 seeds real entries. |
| Approval rollout | The trusted issuer, immutable GitHub storage paths, and offline exporter are shipped, but the protected environment/evidence branch cannot be created or canaried from this feature pull request. | After merge, protect `honeycomb-listing-approval` and `honeycomb-evidence`, then exercise an eligible and ineligible dispatch. |
| Security-lint rollout | Static/unit coverage is shipped, but effective fork permissions and `workflow_run` writes cannot be canaried until both workflows are on the default branch. | After merge, run the documented fork canary and require `honeycomb/security-lint` in branch protection. |
