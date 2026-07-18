# Wiki Gaps

| Area | Gap | Notes |
|------|-----|-------|
| Seed listing approvals | Listing evidence must bind the final package release and PR head, and the PR author cannot issue their own eligible review. | Add another eligible maintainer; Docs Sync needs one current approval and high-risk Bench needs two distinct current approvals. |
| Bench Verified debut | The frozen policy requires two prior clean listed publisher releases plus genuine keyless signature and Actions attestation evidence, but the seed catalog has no prior releases. | Supply qualifying history and release proof, or explicitly amend the seed requirement/trust policy; do not fabricate evidence or silently demote Bench. |
| Lifecycle rollout | Durable state preservation and the protected normalized-evidence path are defined, but emergency transitions have not been canaried on the live repository. | Exercise soft-hide, yank, revoke, and relist against `honeycomb-evidence:normalized/listing-evidence-v1.json` without losing history. |
| Community-review rollout | Trusted-base record/identity validation is live and passes unrelated production PRs, but positive exact-author and impersonated-filename fork cases are not yet canaried. | Canary an exact-author review and an impersonated filename from a fork. |
| Cloudflare check acknowledgement | The corrected main deployment serves the exact snapshot on both production hostnames, while its GitHub Workers build check remained `in_progress` after propagation during the canary audit. | Retain the build/check IDs in the operational handoff and confirm whether Cloudflare eventually terminates or needs an integration repair. |
