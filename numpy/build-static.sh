#!/bin/bash
set -eou pipefail

ARCH_TRIPLET=_wasi_wasm32-wasi

if [ ! -e venv ]; then
  python3.14 -m venv venv
fi

. venv/bin/activate

export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"
export AR="${WASI_SDK_PATH}/bin/ar"
export RANLIB=true

export PYTHONPATH=$CROSS_PREFIX/lib/python3.14

export CFLAGS="--target=wasm32-wasip1 -I${CROSS_PREFIX}/include/python3.14 -D__EMSCRIPTEN__=1 -DNPY_NO_SIGNAL"
export CXXFLAGS="--target=wasm32-wasip1 -I${CROSS_PREFIX}/include/python3.14"

# Create a fake linker that archives .o files into .a instead of linking a .so.
# This intercepts distutils/setuptools LDSHARED calls.
cat > fake_ldshared.sh <<'EOF'
#!/bin/bash
# fake_ldshared.sh — intercepts LDSHARED calls during numpy build.
# Instead of producing a shared library (.so), we archive all input .o files
# into a static archive (.a) and leave an empty placeholder .so so distutils
# thinks the build succeeded.
set -eou pipefail

AR_BIN="${WASI_SDK_PATH}/bin/ar"
output=""
objects=()

# Parse arguments: find -o <output> and all .o files
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) shift; output="$1" ;;
        *.o) objects+=("$1") ;;
        *) ;;  # ignore flags like --target, -shared, etc.
    esac
    shift
done

if [[ -z "$output" ]]; then
    echo "fake_ldshared: no -o output specified" >&2
    exit 1
fi

# Derive .a path: replace .so (with optional .cpython-* suffix) with .a
archive="${output%.so*}.a"

if [[ ${#objects[@]} -gt 0 ]]; then
    "$AR_BIN" rcs "$archive" "${objects[@]}"
    echo "fake_ldshared: created $archive from ${#objects[@]} objects"
else
    # No objects — create empty archive
    "$AR_BIN" rcs "$archive"
    echo "fake_ldshared: created empty $archive"
fi

# Create empty placeholder .so so distutils install step doesn't fail
touch "$output"
EOF

chmod +x fake_ldshared.sh
export FAKE_LDSHARED="$(pwd)/fake_ldshared.sh"

export LDSHARED="$FAKE_LDSHARED"
# No -shared, no libpython3.14.so — just target flags
export LDFLAGS="--target=wasm32-wasip1"

export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_${ARCH_TRIPLET}
export NPY_DISABLE_SVML=1
export NPY_BLAS_ORDER=
export NPY_LAPACK_ORDER=

pip install cython==3.0.12 setuptools==71.1.0
( cd src && python3 setup.py build --disable-optimization -j 4 )

# Collect all .a files and pure Python files (.py, .pyi)
mkdir -p build-static

# Walk the built lib directory and copy everything, replacing .so placeholders
# with real .a archives
BUILD_LIB_DIR=$(ls -d src/build/lib.*/ 2>/dev/null | head -1)
if [[ -z "$BUILD_LIB_DIR" ]]; then
    echo "ERROR: no build/lib.*/ directory found" >&2
    exit 1
fi

cp -a "${BUILD_LIB_DIR}numpy" build-static/

# Now find all empty .so placeholders and replace them with corresponding .a files
find build-static/numpy -name "*.so" | while read sofile; do
    afile="${sofile%.so*}.a"
    # The .a is in the build/temp.*/ tree — search for it by basename
    basename_a="$(basename "$afile")"
    found_a=$(find src/build/temp.*/ -name "$basename_a" 2>/dev/null | head -1)
    if [[ -n "$found_a" ]]; then
        cp "$found_a" "$afile"
        echo "Installed: $afile"
    else
        echo "WARNING: no .a found for $sofile (searched for $basename_a)"
    fi
done

echo "Build complete. Static archives in build-static/numpy:"
find build-static/numpy -name "*.a" | sort
