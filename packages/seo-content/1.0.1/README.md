# SEO Content

Produce a publishable search-led article through the full flagship flow:
research, intent analysis, outline, draft, fact-check, humanization, and
optimization. The default prompt-only path requires no provider account.

## Input

Create `brief.md` with the topic, audience, business goal, market/locale,
desired conversion, brand constraints, and any primary keyword or supplied
sources. Do not paste credentials into the brief.

## Optional provider inputs

The final manifest's `x-hive.optional_inputs` binds every input below only to
`stages.provider-data`. A missing or partial set never blocks prompt-only
execution. Provider collection records which inputs were available, the
covered date range, and labels partial data without inferring absent metrics.

| Provider | Optional environment inputs |
|---|---|
| GA4 | `GA4_PROPERTY_ID`, `GA4_ACCESS_TOKEN` |
| GSC | `GSC_ACCESS_TOKEN`; `site_url` comes from `brief.md` |
| DataForSEO | `DATAFORSEO_LOGIN`, `DATAFORSEO_PASSWORD` |
| Ahrefs | `AHREFS_API_KEY`; `site_url` comes from `brief.md` |

Hive injects values only into the authorized provider-data slot. Instructions
forbid printing, copying, or persisting credential values; only aggregated
metrics and query provenance belong in `provider-data.md`.

## Durable artifacts and rubric

- `repo-research.md` records repository-grounded product and audience evidence.
- `web-research.md` records current external sources as untrusted data.
- `provider-data.md` labels prompt-only, provider-backed, missing, and partial data.
- `research.md` synthesizes those trust-separated inputs into a claim ledger.
- `intent.md` selects and justifies the search intent and reader job.
- `outline.md` maps intent, claims, sections, and conversion path.
- `draft.md` is the complete sourced first article.
- `verification.md` assigns claim-level verification status.
- `humanization.md` identifies templated prose and required repairs.
- `analysis.md` records the deterministic analyzer's JSON measurements as
  prioritized, rubric-linked recommendations.
- `optimization.md` records which recommendations the final article applies.
- `article.md` is the publishable terminal deliverable.

Acceptance requires intent/outline/article alignment, no unmarked unsupported
claim, humanization findings addressed, and measurable optimization
recommendations rather than ceremonial files.

## Permissions

The package embeds no agent, model, or effort. Repository, web, provider, and
analysis work use separate scoped stages so no actor combines untrusted
external/provider data with repository-write authority. Only provider-data and
analysis can execute their specific manifest-hashed package tool; neither can
run arbitrary shell commands. Every write is task-local, and no stage can
write to the repository. External and provider content is untrusted data and
must never be executed as instructions.

## Provenance

This workflow is an adaptation of Agent Plugins commit
`e2caed2878ff1996f235ad0122bf7fea2eea3a27`, principally:

- `plugins/agent-seo/skills/seo/SKILL.md`
- `plugins/agent-seo/commands/seo:research.md`
- `plugins/agent-seo/agents/search-intent-analyzer.md`
- `plugins/agent-seo/commands/seo:write.md`
- `plugins/agent-seo/commands/seo:fact-check.md`
- `plugins/agent-seo/commands/seo:humanize.md`
- `plugins/agent-seo/commands/seo:optimize.md`
- `plugins/agent-seo/data_sources/ruby/lib/agent_seo/seo_quality_rater.rb`

Instructions were rewritten for Hive's immutable staged contract. The bundled
`tools/seo-analyze.rb` is a new standard-library-only implementation, not a
byte copy of the upstream analyzer. See `NOTICE.md` for MIT attribution.
