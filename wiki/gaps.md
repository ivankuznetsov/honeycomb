# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Command surface | `hive workflow install honeycomb/<name>` is documented but not implemented here. | README says install verbs land with Hive tasks 1852/1853, which are outside this repository. |
| Catalog surface | Root `catalog.json` is generated, but `hive.sh/honeycombs` has no route, handler, or static renderer here. | Static site work consumes `honeycomb-catalog/v1`; task 1851 seeds real entries. |
| Production evidence adapter | `honeycomb-listing-evidence/v1` defines normalized reader semantics, but task 1849's persisted location/serialization is not frozen. | Task 1849 must emit the normalized set directly or adapt its private records before invoking the catalog tool. |
| Security review workflow | Identity gating is implemented, but CI lint creation, approval invalidation, labels/comments, and human process are not. | Await tasks 1849 and 1850. |
| Trust evolution | Catalog v1 has a tier string but no signing, attestation, advisory, yanked, revoked, or historic-tier fields. | Coordinate a later version with trust/site/installer work rather than extending v1 ad hoc. |
