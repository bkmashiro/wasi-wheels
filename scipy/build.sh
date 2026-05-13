#!/bin/bash
# Build scipy 1.17.0 for wasm32-wasip1 (WASI)
# Uses meson + ninja directly (not pip install) to avoid meson-python
# metadata-generation issues with cross-compilation.
# BLAS/LAPACK: lapack_lite (bundled reference, no external dependency).

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

# ── Install host build tools FIRST (before PYTHONPATH override) ───────────────
pip install \
  "meson==1.9.2" \
  ninja \
  "cython==3.0.12" \
  "numpy>=2.0" \
  pyproject_metadata \
  setuptools \
  wheel

# ── Build f2c (host tool: Fortran → C) ───────────────────────────────────────
if [ ! -f f2c/src/f2c ]; then
  echo ">>> Building f2c (host tool)"
  [ -d f2c ] || git clone https://github.com/hoodmane/f2c.git --depth 1
  (cd f2c/src && cp makefile.u makefile && sed -i "s/gram.c:/gram.c1:/" makefile && make -j"$(nproc)")
fi
export F2C="${SCRIPT_DIR}/f2c/src/f2c"

# ── Download scipy source ─────────────────────────────────────────────────────
if [ ! -d "${SCIPY_SRC}" ]; then
  echo ">>> Downloading scipy ${SCIPY_VERSION}"
  curl -fsSL "https://files.pythonhosted.org/packages/source/s/scipy/scipy-${SCIPY_VERSION}.tar.gz" \
    | tar xz
fi

# ── Apply Pyodide patches ─────────────────────────────────────────────────────
# Use a stamp file so we don't re-patch on repeated runs
if [ ! -f "${SCIPY_SRC}/.patched" ]; then
  echo ">>> Applying patches"
  for p in "${SCRIPT_DIR}/patches/"*.patch; do
    echo "  $(basename $p)"
    (cd "${SCIPY_SRC}" && patch -p1 --forward < "$p" 2>/dev/null || true)
  done

  # ── void→int sweep (f2c ABI: Fortran subroutines return int, not void) ──────
  echo ">>> void→int sweep"
  cd "${SCIPY_SRC}"
  sed -i 's/void DQA/int DQA/g' scipy/integrate/__quadpack.h 2>/dev/null || true
  find scipy -name "*.c" -o -name "*.h" | xargs -r grep -l "extern void F_FUNC" 2>/dev/null \
    | xargs -r sed -i 's/extern void F_FUNC/extern int F_FUNC/g' 2>/dev/null || true
  find scipy -name "*.c" -o -name "*.h" | xargs -r grep -l "^void F_FUNC" 2>/dev/null \
    | xargs -r sed -i 's/void F_FUNC/int F_FUNC/g' 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/odr/odrpack.h 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/odr/__odrpack.c 2>/dev/null || true
  sed -i 's/void BLAS_FUNC/int BLAS_FUNC/g' scipy/special/lapack_defs.h 2>/dev/null || true
  sed -i 's/extern void/extern int/g' scipy/optimize/__minpack.h 2>/dev/null || true
  sed -i 's/void/int/g' scipy/linalg/cython_blas_signatures.txt 2>/dev/null || true
  sed -i 's/void/int/g' scipy/linalg/cython_lapack_signatures.txt 2>/dev/null || true
  sed -i 's/^void BLAS_FUNC/int BLAS_FUNC/g' scipy/linalg/src/_common_array_utils.hh 2>/dev/null || true
  find scipy/linalg -maxdepth 1 -name "*.h" \
    | xargs -r sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' 2>/dev/null || true
  find scipy/sparse -name "*.h" \
    | xargs -r sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' 2>/dev/null || true
  find scipy/integrate/src -name "*.h" \
    | xargs -r sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' 2>/dev/null || true
  for hdr in scipy/optimize/__lbfgsb.h scipy/optimize/__nnls.h scipy/optimize/__slsqp.h; do
    [ -f "$hdr" ] && sed -i 's/^void \([a-z0-9]*_\)(/int \1(/g' "$hdr" 2>/dev/null || true
  done
  sed -i 's/void/int/g' scipy/interpolate/src/_fitpackmodule.c 2>/dev/null || true
  sed -i 's/void BLAS_FUNC/int BLAS_FUNC/g' scipy/interpolate/src/__fitpack.h 2>/dev/null || true
  find scipy/sparse/linalg/_dsolve/SuperLU/SRC -name "*.c" -o -name "*.h" \
    | xargs -r sed -i 's/extern void/extern int/g;s/PUBLIC void/PUBLIC int/g;s/^void/int/g' 2>/dev/null || true
  find scipy/sparse/linalg/_dsolve -maxdepth 1 -name "*.c" -o -name "*.h" \
    | xargs -r sed -i 's/^void/int/g' 2>/dev/null || true
  sed -i 's/TYPE_GENERIC_FUNC(\(.*\), void)/TYPE_GENERIC_FUNC(\1, int)/g' \
    scipy/sparse/linalg/_dsolve/_superluobject.h 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/optimize/_trlib/trlib_private.h 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/optimize/_trlib/trlib/trlib_private.h 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/_build_utils/src/wrap_dummy_g77_abi.c 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/spatial/qhull_misc.h 2>/dev/null || true
  echo "" > scipy/sparse/linalg/_dsolve/SuperLU/SRC/input_error.c 2>/dev/null || true
  cd "${SCRIPT_DIR}"

  touch "${SCIPY_SRC}/.patched"
fi

# ── Mock gfortran (no Fortran compiler for WASM; lapack_lite uses pre-f2c'd C) ─
MOCK_BIN="$(mktemp -d)"
printf '#!/bin/bash\necho "gfortran stub"\nexit 1\n' > "${MOCK_BIN}/gfortran"
chmod +x "${MOCK_BIN}/gfortran"
# Prepend wasi-sdk so clang/llvm-ar/etc. are picked up by meson
export PATH="${WASI_SDK_PATH}/bin:${MOCK_BIN}:${PATH}"

# ── Meson cross-file ──────────────────────────────────────────────────────────
HOST_PYTHON="$(which python3.14)"
cat > "${SCRIPT_DIR}/wasi-cross.ini" << EOF
[binaries]
c = 'clang'
cpp = 'clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
# Point meson to the WASI cross-Python for extension suffix / sysconfig queries
python3 = '${CROSS_PREFIX}/bin/python3.14'

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
# meson doesn't know 'wasi' — use 'emscripten' which is the closest known
# WASM target; scipy uses #ifdef __EMSCRIPTEN__ guards we already handle
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

HOST_CYTHON="$(which cython)"

# Native file: tells meson which tools to use on the build (host Linux) machine
cat > "${SCRIPT_DIR}/native.ini" << EOF
[binaries]
python3 = '${HOST_PYTHON}'
cython = '${HOST_CYTHON}'
EOF

# ── Cross-compile env vars ────────────────────────────────────────────────────
WASM_TARGET="--target=wasm32-wasip1"
PY_INC="${CROSS_PREFIX}/include/python3.14"
PY_LIB="${CROSS_PREFIX}/lib/libpython3.14.so"

export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"
export AR="${WASI_SDK_PATH}/bin/llvm-ar"
export RANLIB=true
export LDSHARED="${CC}"
export STRIP="${WASI_SDK_PATH}/bin/llvm-strip"

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
export NPY_BLAS_ORDER=
export NPY_LAPACK_ORDER=

# ── Build with meson + ninja directly ────────────────────────────────────────
BUILD_DIR="${SCRIPT_DIR}/build/_meson"
INSTALL_DIR="${SCRIPT_DIR}/build/scipy_install"
mkdir -p "${BUILD_DIR}" "${INSTALL_DIR}"

echo ">>> meson setup"
cd "${SCRIPT_DIR}/${SCIPY_SRC}"

# Run meson setup with PYTHONPATH unset so meson's python detection uses host Python
PYTHONPATH= meson setup "${BUILD_DIR}" \
  --cross-file="${SCRIPT_DIR}/wasi-cross.ini" \
  --native-file="${SCRIPT_DIR}/native.ini" \
  --prefix="${INSTALL_DIR}" \
  -Dblas=none \
  -Dlapack=none \
  -Dpython.install_env=prefix \
  --wipe 2>&1 | tee /tmp/scipy_meson_setup.log
EXIT=${PIPESTATUS[0]}
if [ "$EXIT" != "0" ]; then
  echo "meson setup failed — log:"
  cat /tmp/scipy_meson_setup.log
  exit "$EXIT"
fi

echo ">>> ninja build"
PYTHONPATH="${CROSS_PREFIX}/lib/python3.14" \
  ninja -C "${BUILD_DIR}" -j"$(nproc)" 2>&1 | tee /tmp/scipy_ninja.log
EXIT=${PIPESTATUS[0]}
if [ "$EXIT" != "0" ]; then
  echo "ninja build failed"
  exit "$EXIT"
fi

echo ">>> ninja install"
PYTHONPATH="${CROSS_PREFIX}/lib/python3.14" \
  ninja -C "${BUILD_DIR}" install

echo ">>> scipy build complete"
echo "Installed to: ${INSTALL_DIR}"
ls "${INSTALL_DIR}" 2>/dev/null || true
