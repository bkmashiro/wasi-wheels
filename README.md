# wasi-wheels

Cross-compiled Python native extension wheels for **wasm32-wasip1** (WASI), targeting CPython 3.14.

This is a fork of [dicej/wasi-wheels](https://github.com/dicej/wasi-wheels), migrated from wasi-sdk-24 + CPython 3.12 to **wasi-sdk-33 + CPython 3.14.0**. All three packages build and release successfully via CI.

## Available Packages

| Package | Version | Status |
|---------|---------|--------|
| numpy | 2.x | ✅ |
| pydantic_core | 2.41.5 | ✅ |
| regex | latest | ✅ |

Pre-built wheels are available on the [Releases page](../../releases) — grab the `latest` pre-release for the most recent build from `main`.

## Toolchain

| Component | Version |
|-----------|---------|
| wasi-sdk | 33 (LLVM 20 / wasm-ld 20) |
| CPython | 3.14.0 |
| Rust target | wasm32-wasip1 |
| maturin | ≥ 1.7 |
| pyo3 | 0.26 |

## Building Locally

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/bkmashiro/wasi-wheels.git
cd wasi-wheels
```

Build everything:

```bash
make
```

Or build individual packages:

```bash
make prerequisites   # Download wasi-sdk + cross-compile CPython 3.14 (takes a while)
make numpy
make pydantic
make regex
```

Built wheels (as `.tar.gz` archives) land in `build/`.

## Using the Wheels

Extract a tarball into your project root so the package directory is importable:

```bash
tar xzf build/numpy-wasi.tar.gz          # extracts numpy/
tar xzf build/pydantic_core-wasi.tar.gz  # extracts pydantic_core/
tar xzf build/regex-wasi.tar.gz          # extracts regex/
```

Then run with a WASI runtime that supports Python (e.g. [componentize-py](https://github.com/bytecodealliance/componentize-py), [wasmtime](https://wasmtime.dev/)).

## CI / Release

GitHub Actions builds on every push to `main` and on version tags (`v*`):

- **Canary release** (`latest` pre-release): updated automatically on each `main` push
- **Versioned release**: created when you push a `v*` tag

Caches: wasi-sdk, CPython WASI build, and Cargo registry are all cached to keep subsequent builds fast (typically under 10 minutes after the first cold build).

## Migration Notes

This fork required non-trivial changes to target wasi-sdk-33 and CPython 3.14. Key issues resolved:

- **`build-details.json` format**: maturin ≥1.7 expects a nested JSON structure; CPython 3.14 generates a flat sysconfig JSON — replaced entirely in both the Makefile and pydantic build script
- **pyo3 version**: pydantic-core 2.14.5 (pyo3 0.20) only supports Python ≤3.12; updated submodule to v2.41.5 (pyo3 0.26) for Python 3.14 support
- **wasm-ld flags**: `--experimental-pic` is still required in LLVM 20; `--unresolved-symbols=import-dynamic` is critical so Python C API symbols become wasm dynamic imports rather than linker errors
- **`linker-plugin-lto`**: dropped — requires matching LLVM between Rust toolchain and wasm-ld; version mismatch causes bitcode format errors
- **Makefile**: added `.PHONY` aliases (`prerequisites`, `numpy`, `pydantic`, `regex`) to work around absolute-path targets; used order-only prerequisites for CPython to avoid cache invalidation

See the [blog post](https://bkmashiro.github.io/posts/projects/wasi-wheels-migration.html) for a full technical write-up (Chinese).

## License

Build scripts are MIT. Each vendored package retains its own license.
