# Submission Canary

`.github/workflows/submission-canary.yml` is a maintainer-dispatched production
smoke path for the real contributor boundary. It creates a fixed
`task-inspect/<semver>` package as `github-actions[bot]`, using one source commit
and a second canonical-manifest commit. A human maintainer must still inspect
the diff, apply `safe-to-validate`, submit a current GitHub review, approve the
protected environment deployment, and dispatch the listing-approval workflow.

The canary deliberately cannot approve itself, write listing evidence, update
the catalog, deploy the site, or bypass normal branch protection. Its only
input is a strict numeric SemVer, and it refuses an existing package directory
or remote branch. The submitted workflow requests the currently lossless Hive
v2 permission shape: low-risk task-local filesystem read with no writes,
network, shell, repository access, or secrets.

GitHub repository settings may disallow pull-request creation by
`GITHUB_TOKEN`. An operator may enable that setting only for the dispatched
canary run and must restore it after the PR is opened. GitHub marks workflow-
created pull-request runs as approval-required; approving those runs is part of
the canary rather than a product bypass.

Registry-original provenance still requires the source commit to remain
reachable after merge. Use a merge commit for the two-commit canary submission,
then restore the default branch's linear-history protection if it was
temporarily relaxed. Do not squash or rebase the submission.

The first production exercise used pull request 10 and `task-inspect/0.1.0`.
It fail-closed before publication when Ruby JSON versions disagreed on evidence
digest bytes, then succeeded after the stable canonical encoder landed. The
refreshed exact head `9ce3648afd6f6f8def80701d89b35448417d0def` is bound to
portable lint digest
`3fb099f20893e900963d85aa056ec8b6a93d29ebc712ea18b503d0fb4d65b554`,
protected normalized evidence, and a provenance-preserving merge to `main`.
