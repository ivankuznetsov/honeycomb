# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Command surface | `hive workflow install honeycomb/<name>` is documented but not implemented here. | README says install verbs land with Hive tasks 1852/1853, which are outside this repository. |
| Catalog surface | Root `catalog.json` is generated, but `hive.sh/honeycombs` has no route, handler, or static renderer here. | Static site work consumes `honeycomb-catalog/v1`; task 1851 seeds real entries. |
| Approval issuance and storage | Lint and approval schemas plus the catalog adapter are shipped, but no trusted maintainer approval issuer or durable record channel is selected. | Task 1850 supplies reviewer policy and issuance; until then real suppression requests remain blocking and catalog approvals are fixture/operator inputs. |
| Security-lint rollout | Static/unit coverage is shipped, but effective fork permissions and `workflow_run` writes cannot be canaried until both workflows are on the default branch. | After merge, run the documented fork canary and require `honeycomb/security-lint` in branch protection. |
| Trust evolution | Catalog v1 has a tier string but no signing, attestation, advisory, yanked, revoked, or historic-tier fields. | Coordinate a later version with trust/site/installer work rather than extending v1 ad hoc. |
