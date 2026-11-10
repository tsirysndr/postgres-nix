# PostgreSQL Nix CI component

This module uses native WIT components with WASI Preview 2. No Extism guest compiler is needed.
CI behavior lives in `src/CI/Nix.purs` and `src/CI/Setup.purs`; `Main.purs` exposes
the public commands. The small JavaScript FFI file only binds the typed native
Determinate Nix dependency. Each build regenerates WIT and bindings from the source contract.
Unsupported or untyped contracts fail instead of generating guessed signatures.

```sh
fluentci install --frozen-lockfile
fluentci run --frozen-lockfile ci prepare
```

Run these commands from the repository root with the pinned PureScript/Spago
toolchain installed. `prepare` builds and tests the component, then stages the
fully composed artifact as `.fluentci/ci/dist/ci.wasm`. It never runs Nix builds.
The ten host-fixture regression tests execute the actual compiled PureScript
and cover failure propagation, native platform checks and final binary reporting.
Preparation also checks the real host's explicit environment, stdout journal
and file-query contracts without invoking Nix.

`fluentci run --wasm .fluentci/ci/dist/ci.wasm check --system x86_64-linux` runs
the complete pipeline, including installation through the native
`setup-determinate-nix@v0.2.1` dependency. Run `check` only on an intended build host.
See [the component guide](https://docs.fluentci.io/guides/components/) for supported types, host imports and toolchains.
