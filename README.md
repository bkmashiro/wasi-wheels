# wasi-wheels

Cross-compiled Python native extension wheels for **wasm32-wasip1** (WASI), targeting CPython 3.14.

Fork of [dicej/wasi-wheels](https://github.com/dicej/wasi-wheels), migrated from wasi-sdk-24 + CPython 3.12 to **wasi-sdk-33 + CPython 3.14.0**. All three packages build, release, and run successfully via [componentize-py](https://github.com/bytecodealliance/componentize-py).

## Available Packages

| Package | Version | Status |
|---------|---------|--------|
| numpy | 1.26.0b1 | ✅ |
| pydantic_core | 2.41.5 | ✅ |
| regex | latest | ✅ |

Pre-built wheels are on the [Releases page](../../releases) — grab the `latest` pre-release for the most recent build from `main`.

## Quick Start with componentize-py

Install componentize-py and wasmtime:

```bash
pip install componentize-py==0.23.0
# wasmtime: https://github.com/bytecodealliance/wasmtime/releases
```

Download and extract the wheels you need:

```bash
curl -OL https://github.com/bkmashiro/wasi-wheels/releases/download/latest/numpy-wasi.tar.gz
curl -OL https://github.com/bkmashiro/wasi-wheels/releases/download/latest/pydantic_core-wasi.tar.gz
curl -OL https://github.com/bkmashiro/wasi-wheels/releases/download/latest/regex-wasi.tar.gz
tar xzf numpy-wasi.tar.gz
tar xzf pydantic_core-wasi.tar.gz
tar xzf regex-wasi.tar.gz
```

Write your WIT world and Python app, then componentize:

```bash
componentize-py -d wit -w my-world componentize app -o app.wasm
wasmtime run app.wasm
```

See the [matrix-math example](https://github.com/bytecodealliance/componentize-py/tree/main/examples/matrix-math) in the componentize-py repo for a full working example with numpy.

## Verified Integration

Tested end-to-end with componentize-py 0.23.0 + wasmtime 44:

```
[OK] regex:         match, findall — functional
[OK] pydantic_core: v2.41.5, SchemaValidator — functional
[OK] numpy:         v1.26.0b1, array math — functional
```

All three packages compile into a single WASM component and run correctly under wasmtime.

## Toolchain

| Component | Version |
|-----------|---------|
| wasi-sdk | 33 (LLVM 20 / wasm-ld 20) |
| CPython | 3.14.0 |
| Rust target | wasm32-wasip1 |
| maturin | ≥ 1.7 |
| pyo3 | 0.26 |
| componentize-py | 0.23.0 |

## Building Locally

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/bkmashiro/wasi-wheels.git
cd wasi-wheels
```

Build individual packages (or all at once with `make`):

```bash
make prerequisites   # Download wasi-sdk + cross-compile CPython 3.14 (~20 min, cached after first run)
make numpy
make pydantic
make regex
```

Built wheels (as `.tar.gz` archives) land in `build/`.

## CI / Release

GitHub Actions builds on every push to `main` and on version tags (`v*`):

- **Canary release** (`latest` pre-release): updated automatically on each `main` push
- **Versioned release**: created when you push a `v*` tag

Caches for wasi-sdk, CPython WASI build, and Cargo registry keep subsequent CI runs fast (typically under 10 minutes).

## Migration Notes

This fork required non-trivial changes to target wasi-sdk-33 and CPython 3.14. Key issues resolved:

- **`build-details.json` format**: maturin ≥1.7 expects a nested JSON structure; CPython 3.14 generates a flat sysconfig JSON — replaced entirely
- **pyo3 version**: pydantic-core 2.14.5 (pyo3 0.20) only supports Python ≤3.12; updated to v2.41.5 (pyo3 0.26) for Python 3.14
- **wasm-ld flags**: `--experimental-pic` still required in LLVM 20; `--unresolved-symbols=import-dynamic` is critical for Python C API symbol resolution
- **`linker-plugin-lto`**: dropped due to LLVM version mismatch between Rust toolchain and wasm-ld
- **Makefile**: `.PHONY` aliases for CI; order-only prerequisites for CPython to avoid cache invalidation


## License

Build scripts are MIT. Each vendored package retains its own license.
