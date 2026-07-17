---
reviewer: "carol-reviewer"
name: "example"
version: "1.0.0"
source_sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
release_sha256: "2260a4a9f7db0df2f6993ee240cfe83d9fb30d72fd09ab4e31e068c8cd73c14f"
head_sha: "dddddddddddddddddddddddddddddddddddddddd"
reviewed_at: "2026-07-17"
verdict: "warn"
conflict_of_interest: "none"
---
# Community review

## Scope reviewed

I reviewed the immutable package and tested its documented workflow in a
disposable public fixture repository. I did not test repositories containing
secrets.

## Permission observations

The generated permissions are read-only, but the instruction in
`instructions/build.md` asks the agent to summarize every matching file. That
scope can expose sensitive repository text in the model context even without a
write or secret permission.

## Findings

In the disposable fixture, the summary included a file marked confidential by
project convention because the workflow has no documented exclusion pattern.
The reproduction used only synthetic data and is described in the review pull
request.

## Rationale

The manifest accurately reports read access, but users may mistake read-only
for low data-exposure risk. I recommend an explicit allowlist before use on a
sensitive repository.
