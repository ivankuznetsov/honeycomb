Outcome: state-stale
Basis-Digest: sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
Reviewed-Repository-State: {"schema":"honeycomb-repository-state/v1","status":"ok","fingerprint":"sha256:6666666666666666666666666666666666666666666666666666666666666666"}
Terminal-Repository-State: {"schema":"honeycomb-repository-state/v1","status":"ok","fingerprint":"sha256:7777777777777777777777777777777777777777777777777777777777777777"}
Comparison-Base: 89abcdef0123456789abcdef0123456789abcdef
Drift-Source: test-evidence
External-Or-Test-Mutation: true
Repair-Absorbed-Drift: false
Required-Verification: invalidated
Refs-Unchanged: true
Prior-Verdicts-Stale: true
Analytical-Only: true
Owner-Authority: sole-owner
Human-Approval: false

# Invalidated panel state

The test-evidence command changed the worktree after the reviewed checkpoint.
The workflow preserved both fingerprints, invalidated every prior lens result,
and did not restore, absorb, or relabel the drift as a repair. The owner must
identify the writer and choose a fresh review state.

This analytical state warning is not human or merge approval and grants no
registry, release, publication, or deployment authority.
