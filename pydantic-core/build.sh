#!/bin/bash

set -eou pipefail

if [ ! -e venv ]; then
  echo 'creating venv'
  python3.14 -m venv venv
fi

. venv/bin/activate
pip install typing-extensions wheel maturin setuptools

ARCH_TRIPLET=_wasi_wasm32-wasi

export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"

export PYTHONPATH=$CROSS_PREFIX/lib/python3.14

RUSTFLAGS="${RUSTFLAGS:-} -C link-args=-L${WASI_SDK_PATH}/share/wasi-sysroot/lib/wasm32-wasip1/"
RUSTFLAGS="${RUSTFLAGS} -C linker=${WASI_SDK_PATH}/bin/wasm-ld"
RUSTFLAGS="${RUSTFLAGS} -C link-self-contained=no"
RUSTFLAGS="${RUSTFLAGS} -C link-args=--experimental-pic"
RUSTFLAGS="${RUSTFLAGS} -C link-args=--shared"
RUSTFLAGS="${RUSTFLAGS} -C relocation-model=pic"
RUSTFLAGS="${RUSTFLAGS} -C linker-plugin-lto=yes"
export RUSTFLAGS="$RUSTFLAGS"

export CFLAGS="-I${CROSS_PREFIX}/include/python3.14 -D__EMSCRIPTEN__=1"
export CXXFLAGS="-I${CROSS_PREFIX}/include/python3.14"
export LDSHARED=${CC}
export AR="${WASI_SDK_PATH}/bin/ar"
export RANLIB=true
export LDFLAGS="-shared"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_${ARCH_TRIPLET}
export CARGO_BUILD_TARGET=wasm32-wasip1

# maturin >= 1.7 expects build-details.json with a nested structure:
#   { "language": {"version": "3.14"}, "implementation": {"name": "CPython"},
#     "abi": {"flags": [], "extension_suffix": ".cpython-314-wasm32-wasi.so"} }
# CPython 3.14 WASI cross-build generates a flat sysconfig-variable JSON instead.
# We replace it with the maturin-expected format every time (cache-safe).
python3 - <<'PYEOF'
import json, os, sys

pyo3_dir = os.environ.get('PYO3_CROSS_LIB_DIR', '')
if not pyo3_dir:
    print('ERROR: PYO3_CROSS_LIB_DIR is not set', file=sys.stderr)
    sys.exit(1)

p = pyo3_dir + '/build-details.json'
print(f'Writing maturin-format build-details.json to: {p}')

maturin_build_details = {
    "language": {"version": "3.14"},
    "implementation": {"name": "CPython"},
    "abi": {
        "flags": [],
        "extension_suffix": ".cpython-314-wasm32-wasi.so"
    }
}

with open(p, 'w') as f:
    json.dump(maturin_build_details, f, indent=2)

# Verify
with open(p) as f:
    content = f.read()
print(f'Wrote {len(content)} bytes:')
print(content)
PYEOF

cd src
rm -rf build
mkdir build
maturin build --release --target wasm32-wasip1 --out dist -i python3.14 -vvv
wheel unpack --dest build dist/*.whl 
