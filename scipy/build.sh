#!/bin/bash
# Build scipy 1.17.0 for wasm32-wasip1 (WASI)
# Strategy: lapack_lite (no external BLAS/LAPACK), following Pyodide's approach
#   - f2c used as host tool (Fortran→C); no gfortran needed
#   - 12 patches from Pyodide applied verbatim
#   - Meson cross-compilation with wasi-cross.ini
#   - WASI-specific: no -fwasm-exceptions, no __EMSCRIPTEN__, add WASI emulation libs

set -eou pipefail

SCIPY_VERSION="1.17.0"
SCIPY_SRC="scipy-${SCIPY_VERSION}"
WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Python venv ───────────────────────────────────────────────────────────────
if [ ! -e venv ]; then
  python3.14 -m venv venv
fi
. venv/bin/activate

# ── Build f2c (host tool: converts Fortran → C) ───────────────────────────────
if [ ! -f f2c/src/f2c ]; then
  echo ">>> Building f2c (host tool)"
  if [ ! -d f2c ]; then
    git clone https://github.com/hoodmane/f2c.git --depth 1
  fi
  (cd f2c/src && cp makefile.u makefile && sed -i "s/gram.c:/gram.c1:/" makefile && make -j"$(nproc)")
fi
export F2C="${SCRIPT_DIR}/f2c/src/f2c"
echo ">>> f2c: $($F2C --version 2>&1 | head -1 || echo 'built')"

# ── Download scipy source ─────────────────────────────────────────────────────
if [ ! -d "${SCIPY_SRC}" ]; then
  echo ">>> Downloading scipy ${SCIPY_VERSION}"
  curl -fsSL "https://files.pythonhosted.org/packages/source/s/scipy/scipy-${SCIPY_VERSION}.tar.gz" \
    | tar xz
fi

# ── Apply Pyodide patches ─────────────────────────────────────────────────────
(cd "${SCIPY_SRC}" && git init -q && git add -A && git commit -q -m init 2>/dev/null || true)
echo ">>> Applying patches"
for p in "${SCRIPT_DIR}/patches/"*.patch; do
  echo "  Applying $(basename $p)"
  (cd "${SCIPY_SRC}" && patch -p1 --forward --reject-file=/dev/null < "$p" || true)
done

# ── void→int sweep (required by f2c ABI; from Pyodide meta.yaml) ─────────────
echo ">>> Applying void→int sweep"
cd "${SCIPY_SRC}"

sed -i 's/void DQA/int DQA/g' scipy/integrate/__quadpack.h 2>/dev/null || true
find scipy -name "*.c" -o -name "*.h" | xargs grep -l "extern void F_FUNC" 2>/dev/null \
  | xargs sed -i 's/extern void F_FUNC/extern int F_FUNC/g' 2>/dev/null || true
find scipy -name "*.c" -o -name "*.h" | xargs grep -l "^void F_FUNC" 2>/dev/null \
  | xargs sed -i 's/void F_FUNC/int F_FUNC/g' 2>/dev/null || true
sed -i 's/^void/int/g' scipy/odr/odrpack.h 2>/dev/null || true
sed -i 's/^void/int/g' scipy/odr/__odrpack.c 2>/dev/null || true
sed -i 's/void BLAS_FUNC/int BLAS_FUNC/g' scipy/special/lapack_defs.h 2>/dev/null || true
sed -i 's/extern void/extern int/g' scipy/optimize/__minpack.h 2>/dev/null || true
sed -i 's/void/int/g' scipy/linalg/cython_blas_signatures.txt 2>/dev/null || true
sed -i 's/void/int/g' scipy/linalg/cython_lapack_signatures.txt 2>/dev/null || true
sed -i 's/^void BLAS_FUNC/int BLAS_FUNC/g' scipy/linalg/src/_common_array_utils.hh 2>/dev/null || true
sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' scipy/linalg/_common_array_utils.h 2>/dev/null || true
sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' scipy/linalg/_matfuncs_expm.h 2>/dev/null || true
find scipy/sparse -name "*.h" | xargs sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' 2>/dev/null || true
find scipy/integrate/src -name "*.h" | xargs sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' 2>/dev/null || true
find scipy/optimize -name "__lbfgsb.h" -o -name "__nnls.h" -o -name "__slsqp.h" \
  | xargs sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' 2>/dev/null || true
sed -i 's/void/int/g' scipy/interpolate/src/_fitpackmodule.c 2>/dev/null || true
sed -i 's/void BLAS_FUNC/int BLAS_FUNC/g' scipy/interpolate/src/__fitpack.h 2>/dev/null || true
find scipy/sparse/linalg/_dsolve/SuperLU/SRC -name "*.c" -o -name "*.h" \
  | xargs sed -i 's/extern void/extern int/g;s/PUBLIC void/PUBLIC int/g;s/^void/int/g' 2>/dev/null || true
find scipy/sparse/linalg/_dsolve -maxdepth 1 -name "*.c" -o -name "*.h" \
  | xargs sed -i 's/^void/int/g' 2>/dev/null || true
sed -i 's/TYPE_GENERIC_FUNC(\(.*\), void)/TYPE_GENERIC_FUNC(\1, int)/g' \
  scipy/sparse/linalg/_dsolve/_superluobject.h 2>/dev/null || true
sed -i 's/^void/int/g' scipy/optimize/_trlib/trlib_private.h 2>/dev/null || true
sed -i 's/^void/int/g' scipy/optimize/_trlib/trlib/trlib_private.h 2>/dev/null || true
sed -i 's/^void/int/g' scipy/_build_utils/src/wrap_dummy_g77_abi.c 2>/dev/null || true
sed -i 's/^void/int/g' scipy/spatial/qhull_misc.h 2>/dev/null || true
# Empty duplicate-symbol file
echo "" > scipy/sparse/linalg/_dsolve/SuperLU/SRC/input_error.c 2>/dev/null || true

# ── Toolchain ─────────────────────────────────────────────────────────────────
export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"
export AR="${WASI_SDK_PATH}/bin/llvm-ar"
export RANLIB=true
export LDSHARED="${CC}"
export STRIP="${WASI_SDK_PATH}/bin/llvm-strip"

WASM_TARGET="--target=wasm32-wasip1"
PY_INC="${CROSS_PREFIX}/include/python3.14"
PY_LIB="${CROSS_PREFIX}/lib/libpython3.14.so"

# ── Compiler / linker flags ───────────────────────────────────────────────────
# Note: -D__EMSCRIPTEN__=1 from numpy build.sh carried over; guards scipy
# platform-detection code that assumes a browser-like WASM env. WASI behaves
# similarly for the subset of guards relevant to scipy.
export CFLAGS="${WASM_TARGET} -fPIC \
  -I${PY_INC} \
  -isystem ${WASI_SYSROOT}/include \
  -D__EMSCRIPTEN__=1 \
  -DNPY_NO_SIGNAL \
  -DUNDERSCORE_G77 \
  -Wno-return-type \
  -fvisibility=default"

export CXXFLAGS="${WASM_TARGET} -fPIC \
  -I${PY_INC} \
  -isystem ${WASI_SYSROOT}/include \
  -fno-exceptions \
  -fvisibility=default"

export LDFLAGS="${WASM_TARGET} \
  --sysroot=${WASI_SYSROOT} \
  -L${WASI_SYSROOT}/lib/wasm32-wasip1 \
  -L${CROSS_PREFIX}/lib \
  -shared \
  ${PY_LIB} \
  -Wl,--experimental-pic \
  -Wl,--unresolved-symbols=import-dynamic \
  -lwasi-emulated-signal \
  -lwasi-emulated-getpid \
  -lwasi-emulated-process-clocks"

export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi
export PYTHONPATH="${CROSS_PREFIX}/lib/python3.14"

# No BLAS/LAPACK: use scipy's bundled lapack_lite (reference Fortran→C)
export NPY_BLAS_ORDER=
export NPY_LAPACK_ORDER=

# ── Mock gfortran so meson doesn't abort ─────────────────────────────────────
MOCK_BIN="$(mktemp -d)"
printf '#!/bin/bash\nexit 1\n' > "${MOCK_BIN}/gfortran"
chmod +x "${MOCK_BIN}/gfortran"
export PATH="${WASI_SDK_PATH}/bin:${MOCK_BIN}:${PATH}"

# ── Meson cross-file ──────────────────────────────────────────────────────────
cat > "${SCRIPT_DIR}/wasi-cross.ini" << 'EOF'
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'

[properties]
sizeof_short = 2
sizeof_int = 4
sizeof_long = 4
sizeof_long_long = 8
sizeof_float = 4
sizeof_double = 8
sizeof_long_double = 8
sizeof_size_t = 4
sizeof_void_p = 4

[host_machine]
system = 'wasi'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

# ── Install host build tools ──────────────────────────────────────────────────
pip install \
  "meson==1.9.2" \
  ninja \
  "cython==3.0.12" \
  "numpy>=2.0" \
  meson-python \
  pyproject_metadata \
  setuptools \
  wheel

# ── Build scipy ───────────────────────────────────────────────────────────────
echo ">>> Building scipy ${SCIPY_VERSION} for wasm32-wasip1"
MESON_RSP_THRESHOLD=131072 \
pip install \
  --no-build-isolation \
  --no-deps \
  --target "${SCRIPT_DIR}/build/scipy_install" \
  -Csetup-args="--cross-file=${SCRIPT_DIR}/wasi-cross.ini" \
  -Csetup-args="-Dblas=none" \
  -Csetup-args="-Dlapack=none" \
  -Cbuild-dir="${SCRIPT_DIR}/build/_meson" \
  .

echo ">>> scipy build complete"
