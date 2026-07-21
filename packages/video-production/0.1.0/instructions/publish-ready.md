# Record the local publish-ready outcome

Read `verification.md` and `editorial-approval.md`. Run only the declared
`tools/video-production.rb publish-ready` command with the exact manifest,
scene, take, verification, and checked editorial approval. The tool must reject
identity or fingerprint drift and write `publish-ready.json` inside the
selected take.

Return that same JSON as the stage deliverable. Its only successful status is
`publish-ready`, and `published` must remain `false`. This terminal stage is a
local evidence handoff. It does not confer authority for any network or remote
operation, private-to-public selection, permission change, or release action.
Do not substitute console output for the manifest, tool, approval,
verification, artifact hashes, and local artifact paths preserved in the
deliverable.
