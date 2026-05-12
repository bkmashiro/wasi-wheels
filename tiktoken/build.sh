#!/bin/bash

set -eou pipefail

if [ ! -e venv ]; then
  python3.14 -m venv venv
fi

. venv/bin/activate
pip install setuptools setuptools-rust wheel

ARCH_TRIPLET=_wasi_wasm32-wasi

export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"

export PYTHONPATH="$CROSS_PREFIX/lib/python3.14:$SYSCONFIG"

# Same linker flags as pydantic-core (wasi-sdk-33 / LLVM 20):
# --experimental-pic: required in wasm-ld 20
# --unresolved-symbols=import-dynamic: Python C API symbols resolved at runtime
# linker-plugin-lto dropped: LLVM version mismatch between Rust toolchain and wasm-ld
RUSTFLAGS="${RUSTFLAGS:-} -C link-args=-L${WASI_SDK_PATH}/share/wasi-sysroot/lib/wasm32-wasip1/"
RUSTFLAGS="${RUSTFLAGS} -C linker=${WASI_SDK_PATH}/bin/wasm-ld"
RUSTFLAGS="${RUSTFLAGS} -C link-self-contained=no"
RUSTFLAGS="${RUSTFLAGS} -C link-args=--experimental-pic"
RUSTFLAGS="${RUSTFLAGS} -C link-args=--shared"
RUSTFLAGS="${RUSTFLAGS} -C link-args=--unresolved-symbols=import-dynamic"
RUSTFLAGS="${RUSTFLAGS} -C relocation-model=pic"
export RUSTFLAGS="$RUSTFLAGS"

export CFLAGS="-I${CROSS_PREFIX}/include/python3.14 -D__EMSCRIPTEN__=1"
export CXXFLAGS="-I${CROSS_PREFIX}/include/python3.14"
export LDSHARED=${CC}
export AR="${WASI_SDK_PATH}/bin/ar"
export RANLIB=true
export LDFLAGS="-shared"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_${ARCH_TRIPLET}
export CARGO_BUILD_TARGET=wasm32-wasip1

# Write maturin-format build-details.json expected by pyo3 >= 0.22
python3 - <<'PYEOF'
import json, os, sys
p = os.environ['SYSCONFIG'] + '/build-details.json'
json.dump({
    "language": {"version": "3.14"},
    "implementation": {"name": "CPython"},
    "abi": {"flags": [], "extension_suffix": ".cpython-314-wasm32-wasi.so"}
}, open(p, 'w'), indent=2)
print(f'Wrote {p}')
PYEOF

# tiktoken 0.12.0 uses setuptools-rust (not maturin).
# The setup.py enables the "python" feature which pulls in pyo3.
# We also need "generate-import-lib" for pyo3 to resolve Python C API symbols.
cargo="$(<src/Cargo.toml sed -e '/^pyo3 = /s/features = \[/features = ["generate-import-lib", /g')"
echo "$cargo" > src/Cargo.toml

(cd src && python3 setup.py bdist_wheel --dist-dir dist)
wheel unpack --dest build src/dist/tiktoken-*.whl
