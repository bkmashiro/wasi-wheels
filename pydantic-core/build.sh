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

# maturin >= 1.7 requires extension_suffix in build-details.json.
# CPython 3.14 WASI cross-build doesn't generate it; patch it here
# (runs every time, unlike the Makefile recipe which is skipped on cache hit).
python3 - <<'PYEOF'
import json, os, sys
p = os.environ.get('PYO3_CROSS_LIB_DIR', '') + '/build-details.json'
try:
    with open(p) as f:
        d = json.load(f)
    if 'extension_suffix' not in d:
        d['extension_suffix'] = d.get('EXT_SUFFIX', '.cpython-314-wasm32-wasi.so')
        with open(p, 'w') as f:
            json.dump(d, f, indent=2)
        print(f'Patched build-details.json: extension_suffix = {d["extension_suffix"]}')
    else:
        print(f'build-details.json already has extension_suffix: {d["extension_suffix"]}')
except Exception as e:
    print(f'Warning: could not patch build-details.json: {e}', file=sys.stderr)
PYEOF

cd src
rm -rf build
mkdir build
maturin build --release --target wasm32-wasip1 --out dist -i python3.14 -vvv
wheel unpack --dest build dist/*.whl 
