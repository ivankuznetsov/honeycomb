# Command and API Surface

This page tracks the public surfaces that are currently documented for
`honeycomb`. As of the README change in commit `ab7861a`, the repository is
still scaffolding: the command and catalog surfaces are described, but no local
routes, handlers, executable entrypoints, package files, or catalog generator
exist in this repository yet.

## Public Terms

- A published Hive workflow package is a **honeycomb**.
- The public catalog is named `hive.sh/honeycombs`.
- User-facing surfaces should use "honeycomb" for published workflow packages.

## Documented Install Command

The README documents the intended install form:

```sh
hive workflow install honeycomb/<name>
```

The README also says the install verbs land with Hive tasks 1852/1853, outside
this repository. Treat this as a documented future Hive CLI integration rather
than a command implemented by this repository.

## Package Shape

The README defines a honeycomb as:

- a descriptor named `workflow.yml`;
- stage instructions;
- a manifest with version, author, permissions summary, and sha256 integrity.

The Hive inbox task `registry-layout-package-manifest-schema-260709-1f1a`
contains the fuller planned package layout: `packages/<name>/`, `README.md`,
`manifest.yml`, generated top-level `catalog.json`, and a Ruby validator script.
Those files are not present yet.

## Catalog and API Status

`hive.sh/honeycombs` is documented as the catalog URL. The current repository
does not contain a web app, route table, API handler, generated `catalog.json`,
or executable entrypoint. Until implementation lands, consumers should treat the
catalog and install command as README-level product direction.
