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

export LDFLAGS="--target=wasm32-wasip1"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_${ARCH_TRIPLET}
export NPY_DISABLE_SVML=1
export NPY_BLAS_ORDER=
export NPY_LAPACK_ORDER=

pip install cython==3.0.12 setuptools==71.1.0

# Build numpy (this produces .o files in build/temp.*/ and empty .so in build/lib.*/)
# We let numpy link normally (real clang++) to produce placeholder .so files,
# but we also create .a archives from the .o files in build/temp.*
( cd src && python3 setup.py build --disable-optimization -j 4 ) || true

# Collect pure Python and make build-static directory
mkdir -p build-static

BUILD_LIB_DIR=$(ls -d src/build/lib.*/ 2>/dev/null | head -1)
if [[ -z "$BUILD_LIB_DIR" ]]; then
    echo "ERROR: no build/lib.*/ directory found" >&2
    exit 1
fi

# Copy all Python files (including .so placeholders and any .a already made)
cp -a "${BUILD_LIB_DIR}numpy" build-static/

# Now create .a archives from the .o files in build/temp.*/
# The temp directory structure mirrors the source: numpy/core/_multiarray_umath/.../*.o
TEMP_DIR=$(ls -d src/build/temp.*/ 2>/dev/null | head -1)
if [[ -z "$TEMP_DIR" ]]; then
    echo "ERROR: no build/temp.*/ directory found" >&2
    exit 1
fi

echo "=== Creating static archives from temp objects ==="
# For each .so in build-static, find corresponding .o files in temp dir
find build-static/numpy -name "*.so" | while read sofile; do
    # Get module name: e.g. _multiarray_umath from _multiarray_umath.cpython-314-wasm32-wasi.so
    basename_so="$(basename "$sofile")"
    module_stem="${basename_so%%.cpython*}"
    # Target .a path
    afile="${sofile%%.cpython*}.a"

    if [[ -f "$afile" ]]; then
        echo "Already exists: $afile"
        continue
    fi

    # Find all .o files under the module's temp subdirectory
    # numpy puts them in e.g.: build/temp.linux-x86_64-cpython-314/numpy/core/_multiarray_umath/...
    # or in: build/temp.linux-x86_64-cpython-314/numpy/random/_bounded_integers.o
    objects=$(find "${TEMP_DIR}" -name "*.o" | grep -E "/${module_stem}[/.]" | sort | tr '\n' ' ')

    if [[ -n "$objects" ]]; then
        "${WASI_SDK_PATH}/bin/ar" rcs "$afile" $objects
        obj_count=$(echo "$objects" | tr ' ' '\n' | grep -c '\.o$' || true)
        echo "Created: $afile ($obj_count objects)"
    else
        echo "WARNING: no .o files found for module '$module_stem' (so: $sofile)"
    fi
done

echo ""
echo "=== Build complete. Static archives in build-static/numpy: ==="
find build-static/numpy -name "*.a" | sort
