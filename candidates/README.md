# Unpublished workflow candidates

This directory holds locally verified workflow sources that are not Honeycomb
package submissions. Candidate versions intentionally have no `manifest.yml`,
are outside the canonical `packages/<name>/<version>` tree, and are ignored by
catalog generation and package-wide validation.

Moving a candidate into `packages/` begins the separately authorized
publication flow. That change must satisfy `CONTRIBUTING.md`, including source
provenance, a generated canonical manifest, security review, and protected
listing evidence. A candidate commit, passing test, or pull request does not
authorize a release, catalog listing, site deployment, or Hive template
removal.
