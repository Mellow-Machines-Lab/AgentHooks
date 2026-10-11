# Contributing

Issues and pull requests are welcome here.

## Building and testing

```sh
swift build
swift test
```

With the Command Line Tools and no Xcode, `swift test` sometimes fails
with "plugin for module 'TestingMacros' not found" (or "external macro
implementation … TestingMacros"). It's a toolchain flake: run it again
and it passes.

## A few rules

- **Foundation only.** The package has no dependencies, and should keep
  it that way.
- **Record a new agent version before supporting it.** Add its hooks as
  a fixture under `Tests/AgentHooksTests/Fixtures/`.
  [VERSIONS.md](Tests/AgentHooksTests/Fixtures/VERSIONS.md) says how.
- **Pull requests are squash-merged**, so each one lands as a single
  commit.

To report a security problem, see [SECURITY.md](SECURITY.md) instead.
