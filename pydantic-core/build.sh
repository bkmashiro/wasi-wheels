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
echo "=== build-details.json diagnostics ==="
echo "PYO3_CROSS_LIB_DIR=${PYO3_CROSS_LIB_DIR:-<not set>}"
echo "CROSS_PREFIX=${CROSS_PREFIX:-<not set>}"
echo "--- Searching for ALL build-details.json files ---"
find "${CROSS_PREFIX}" "${PYO3_CROSS_LIB_DIR:-/nonexistent}" -name 'build-details.json' 2>/dev/null | sort -u | while read f; do
  echo "FOUND: $f"
  echo "--- CONTENT of $f ---"
  cat "$f"
  echo ""
done
echo "--- End search ---"
python3 - <<'PYEOF'
import json, os, sys

pyo3_dir = os.environ.get('PYO3_CROSS_LIB_DIR', '')
cross_prefix = os.environ.get('CROSS_PREFIX', '')

print(f'PYO3_CROSS_LIB_DIR = {repr(pyo3_dir)}')
print(f'CROSS_PREFIX = {repr(cross_prefix)}')

p = pyo3_dir + '/build-details.json'
print(f'Patching: {repr(p)}')

try:
    with open(p) as f:
        raw = f.read()
    print(f'--- Raw file content ({len(raw)} bytes) ---')
    print(raw)
    print('--- End raw content ---')
    d = json.loads(raw)
    print(f'Top-level keys: {list(d.keys())}')

    changed = False
    # Check if extension_suffix is top-level
    if 'extension_suffix' not in d:
        d['extension_suffix'] = d.get('EXT_SUFFIX', '.cpython-314-wasm32-wasi.so')
        changed = True
        print(f'Added top-level extension_suffix = {d["extension_suffix"]}')
    else:
        print(f'Already has top-level extension_suffix: {d["extension_suffix"]}')

    if changed:
        new_content = json.dumps(d, indent=2)
        with open(p, 'w') as f:
            f.write(new_content)
        # Verify the write
        with open(p) as f:
            verify = f.read()
        print(f'--- Verified file after write ({len(verify)} bytes) ---')
        print(verify)
        print('--- End verified content ---')
    else:
        print('No change needed — verifying current content:')
        with open(p) as f:
            verify = f.read()
        print(verify)
except Exception as e:
    print(f'ERROR patching build-details.json: {e}', file=sys.stderr)
    import traceback; traceback.print_exc()
    sys.exit(1)
PYEOF
echo "=== end build-details.json diagnostics ==="

cd src
rm -rf build
mkdir build
maturin build --release --target wasm32-wasip1 --out dist -i python3.14 -vvv
wheel unpack --dest build dist/*.whl 
