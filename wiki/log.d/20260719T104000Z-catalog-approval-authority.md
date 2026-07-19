# Preserve approval authority in the catalog

- Added explicit independent or repository-owner authority to every projected
  designated approval record.
- Preserved historical evidence semantics by projecting a missing authority as
  independent, matching the eligibility reader.
- Enabled downstream catalog consumers to enforce the high-risk approval gate
  without inferring authority from audit URLs.
