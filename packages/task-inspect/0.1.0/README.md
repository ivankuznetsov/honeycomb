# Task Inspect honeycomb

Produce a concise inventory of the current Hive task workspace without
modifying files, invoking shell commands, accessing the project repository,
using the network, or reading secrets.

## Install

```sh
hive workflow install honeycomb/task-inspect
```

## Permissions

Task Inspect can use only read-oriented tools inside the task workspace.
The generated manifest is the authoritative permission projection.
