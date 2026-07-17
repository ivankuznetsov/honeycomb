---
reviewer: "dave-reviewer"
name: "example"
version: "1.0.0"
source_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
release_sha256: "2260a4a9f7db0df2f6993ee240cfe83d9fb30d72fd09ab4e31e068c8cd73c14f"
head_sha: "dddddddddddddddddddddddddddddddddddddddd"
reviewed_at: "2026-07-17"
verdict: "reject"
conflict_of_interest: "I maintain a competing public workflow; no financial relationship exists."
---
# Community review

## Scope reviewed

I reviewed the package and exercised the documented workflow against a
synthetic repository containing intentionally conflicting instructions. I did
not inspect unpublished upstream branches.

## Permission observations

The read-only permission declaration is accurate for filesystem effects. It
does not mitigate instruction-following behavior inside repository files.

## Findings

The workflow followed a synthetic repository instruction that contradicted the
packaged task and included unrelated fixture content in its response. The
review pull request links a safe reproduction with no real credentials or
private data.

## Rationale

Within this adversarial-input scope, the instruction boundary is insufficient.
I would not use this version until a new immutable release constrains repository
content handling.
