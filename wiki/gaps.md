# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Command surface | `hive workflow install honeycomb/<name>` is documented but not implemented here. | README says install verbs land with Hive tasks 1852/1853, which are outside this repository. |
| Catalog surface | `hive.sh/honeycombs` is documented but no route, handler, static site, or generated catalog exists here. | Await registry/catalog implementation from inbox tasks 1848 and 1851. |
| Package schema | README gives the high-level honeycomb shape, while manifest field details and validation rules are only in inbox task notes. | Confirm when task 1848 lands. |
| Security review | The review gate is documented as core product behavior, but CI, lint output, and human review workflow are not implemented here. | Await tasks 1849 and 1850. |
