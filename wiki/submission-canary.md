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

Publication first exposed an indented catalog at commit
`caa0fa39f723a81a028e2468f7d761d146d71b65`. A fresh released Hive v0.5.2
client then failed closed because those bytes did not match its compact
canonical JSON contract. Pull request 13 corrected the producer and regenerated
the same listing at catalog commit
`bf67e8a6bc4a85e2d6663c57595d337e17ce9f73`, SHA-256
`2e6c27ed6ec22bc3e6afc5ff07244418d48a6e878c53a3e850326748d8d5c497`.

Hive-site pull request 6 merged that exact snapshot as
`f5979cca40a0a2e86a7cafbae581f2c97323b3bd`; both `hivecli.sh/honeycombs/`
and the Workers production hostname served the corrected source revision, the
install command, tier/lifecycle/risk labels, and exact designated-review link.
A public Hive v0.5.2 install from the official registry selected
`task-inspect/0.1.0`, wrote the expected catalog commit and release digest
`37fc8806b3d54a1d304eede69e453a6d131053e50d0007aabcd104f97929c839`
into the managed lock, and copied those pins into a new task's metadata. The
released runtime compiled the package to task-folder-only `Read`, `LS`, `Grep`,
and `Glob`; write, shell, network, skill, subagent, and interactive tools were
denied. Repository permissions and linear-history protection were restored to
their original fail-closed settings after the canary operations. Cloudflare's
replacement Workers check `88115025357` completed successfully on exact site
commit `f5979cca40a0a2e86a7cafbae581f2c97323b3bd`; the earlier in-progress check
record was superseded rather than left as a production blocker.
