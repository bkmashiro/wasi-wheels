#!/bin/bash
set -eou pipefail

ARCH_TRIPLET=_wasi_wasm32-wasi

if [ ! -e venv ]; then
  python3.14 -m venv venv
fi

. venv/bin/activate

export CC="${WASI_SDK_PATH}/bin/clang"
# NOTE: CXX is NOT exported yet — we set it to the fake wrapper below
export AR="${WASI_SDK_PATH}/bin/ar"
export RANLIB=true

REAL_CXX="${WASI_SDK_PATH}/bin/clang++"

export PYTHONPATH=$CROSS_PREFIX/lib/python3.14

export CFLAGS="--target=wasm32-wasip1 -I${CROSS_PREFIX}/include/python3.14 -D__EMSCRIPTEN__=1 -DNPY_NO_SIGNAL"
export CXXFLAGS="--target=wasm32-wasip1 -I${CROSS_PREFIX}/include/python3.14"

export LDFLAGS="--target=wasm32-wasip1"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_${ARCH_TRIPLET}
export NPY_DISABLE_SVML=1
export NPY_BLAS_ORDER=
export NPY_LAPACK_ORDER=

# Create a fake CXX/LDSHARED wrapper that:
#   - When called as a compiler (output is NOT .so): behaves normally
#   - When called as a linker (output IS .so): creates an empty .so and archives .o to .a
#
# NOTE: numpy distutils does NOT pass -shared as an argument when calling $LDSHARED.
# Instead, -shared is baked into the LDSHARED variable itself. So we detect
# shared-link mode by checking if the output filename ends in .so.
cat > fake_cxx.sh <<'FAKECXX_EOF'
#!/bin/bash
# fake_cxx.sh — wraps clang++ to intercept shared-link calls during numpy build.
# Detects shared-link mode by output filename (ends in .so), NOT by -shared flag,
# because numpy distutils puts -shared in LDSHARED itself, not in the arguments.
# For .so output: create empty .so placeholder and archive .o files into .a
# For everything else: pass through to real clang++.
set -eou pipefail

output=""
objects=()

i=1
while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
        -o) i=$((i+1)); output="${!i}" ;;
        *.o) objects+=("$arg") ;;
    esac
    i=$((i+1))
done

# Check if output is a shared library
if [[ -z "$output" ]] || [[ "$output" != *.so && "$output" != *.so.* ]]; then
    # Not a shared-library link step — compile or link normally
    exec "${REAL_CXX}" "$@"
fi

# Shared link step — create archive instead
# Derive .a path from .so path (strip .cpython-*.so suffix)
archive="${output%%.cpython-*.so}.a"
if [[ "$archive" == "$output" ]]; then
    archive="${output%.so}.a"
fi

AR_BIN="${WASI_SDK_PATH}/bin/ar"

if [[ ${#objects[@]} -gt 0 ]]; then
    "$AR_BIN" rcs "$archive" "${objects[@]}"
    echo "fake_cxx: archived ${#objects[@]} objects -> $archive" >&2
else
    "$AR_BIN" rcs "$archive"
    echo "fake_cxx: created empty archive $archive" >&2
fi

# Create empty placeholder .so so setuptools doesn't fail the install step
touch "$output"
FAKECXX_EOF

chmod +x fake_cxx.sh
export REAL_CXX
export CXX="$(pwd)/fake_cxx.sh"
export LDSHARED="$(pwd)/fake_cxx.sh"
export LDCXXSHARED="$(pwd)/fake_cxx.sh"

pip install cython==3.0.12 setuptools==71.1.0

# Clean stale build artifacts so setup.py re-links ALL modules through fake_cxx.
# Without this, setup.py finds cached .so placeholders from a previous build and
# skips re-linking modules that are already "up-to-date", causing fake_cxx to be
# called for only a subset of extensions.
rm -rf src/build/

# Build numpy — the fake_cxx intercepts all shared-link calls by detecting .so output
( cd src && python3 setup.py build --disable-optimization -j 4 )

# Collect pure Python and make build-static directory
mkdir -p build-static

BUILD_LIB_DIR=$(ls -d src/build/lib.*/ 2>/dev/null | head -1)
if [[ -z "$BUILD_LIB_DIR" ]]; then
    echo "ERROR: no build/lib.*/ directory found" >&2
    exit 1
fi

# Copy all files (including .so placeholders and .a archives)
cp -a "${BUILD_LIB_DIR}numpy" build-static/

echo ""
echo "=== Build complete. Static archives in build-static/numpy: ==="
find build-static/numpy -name "*.a" | sort
