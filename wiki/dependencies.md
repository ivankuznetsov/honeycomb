# Dependencies

Confirmed project dependencies are limited because the repository is still
scaffolding.

## Runtime

- Hive is the target consumer for honeycombs and the documented install command
  is `hive workflow install honeycomb/<name>`.
- No local runtime library, server framework, route layer, or executable
  dependency is present in this repository yet.

## Planned Tooling

The Hive inbox task for registry layout proposes a Ruby validator with no
dependencies beyond Ruby stdlib plus YAML. It may soft-depend on Hive's
`DescriptorParser` when the Hive gem is present. This is planned work, not a
current dependency in the repository.

## Services

- `hive.sh/honeycombs` is the documented catalog surface.
- No service implementation or deployment configuration is present here yet.
