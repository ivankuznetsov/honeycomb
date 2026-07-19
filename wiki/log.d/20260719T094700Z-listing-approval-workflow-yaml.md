# Validate listing-approval workflow YAML

- Quoted the responsibility-acknowledgement input description so GitHub can
  parse and dispatch the protected listing-approval workflow.
- Added a workflow contract assertion that parses the YAML, preventing textual
  trigger checks from passing against a syntactically invalid workflow.
