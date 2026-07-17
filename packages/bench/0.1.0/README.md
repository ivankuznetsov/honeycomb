# Bench honeycomb

Run reproducible Hive benchmark campaigns through extract, generate, judge,
and publish stages.

## Install

Requires Hive 0.4.2 or newer:

```sh
hive workflow install honeycomb/bench
```

## Permissions

This is a high-risk honeycomb. Its upstream stages intentionally rely on
Hive's unrestricted default because they execute shell commands, run container
and model-provider tooling, read and write benchmark repositories and run
artifacts, access provider credentials, and use networked model APIs. Review
the generated `manifest.yml` permission union before installation.

## Provenance

This immutable v0.1.0 package vendors the workflow merged by
[Hive Bench PR #1](https://github.com/ivankuznetsov/hive-bench/pull/1) at
commit `b4f462848d439d07e97e1e37943d738e8ca8d28a`:

- `workflows/bench.yml`
- `workflows/bench/extract.md`
- `workflows/bench/generate.md`
- `workflows/bench/judge.md`
- `workflows/bench/publish.md`

The four instruction files are byte-for-byte copies. The only descriptor
translation changes each `./bench/<stage>.md` instruction reference to its
package-relative `instructions/<stage>.md` destination. Behavior is otherwise
unchanged.
