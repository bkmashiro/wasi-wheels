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
  "pybind11>=2.10" \
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

# ── Clang wrapper: strip GNU ld flags wasm-ld doesn't support ────────────────
# Host Python's sysconfig injects --start-group/--end-group (GNU ld only).
# wasm-ld rejects them. Wrap clang to strip them before forwarding.
WRAPPER_DIR="$(mktemp -d)"
cat > "${WRAPPER_DIR}/clang" << 'WEOF'
#!/bin/bash
args=()
for arg in "$@"; do
  case "$arg" in
    -Wl,--start-group|-Wl,--end-group|--start-group|--end-group) ;;
    *) args+=("$arg") ;;
  esac
done
exec "@REAL_CLANG@" "${args[@]}"
WEOF
sed -i "s|@REAL_CLANG@|${WASI_SDK_PATH}/bin/clang|g" "${WRAPPER_DIR}/clang"
chmod +x "${WRAPPER_DIR}/clang"
cp "${WRAPPER_DIR}/clang" "${WRAPPER_DIR}/clang++"
sed -i "s|${WASI_SDK_PATH}/bin/clang\b|${WASI_SDK_PATH}/bin/clang++|g" "${WRAPPER_DIR}/clang++"

# ── Fake gfortran: converts Fortran→C via f2c, then compiles with WASI clang ──
# scipy has Fortran sources beyond lapack_lite (linalg, integrate, optimize...).
# This wrapper is transparent to meson: it accepts gfortran's CLI, uses f2c
# to transpile .f/.f90 files to C, then cross-compiles with wasi-sdk clang.
MOCK_BIN="$(mktemp -d)"

# f2c.h is already in the cloned f2c repo — no download needed
F2C_H="${SCRIPT_DIR}/f2c/src/f2c.h"
echo ">>> Using f2c.h from ${F2C_H} ($(wc -l < "${F2C_H}") lines)"

REAL_CLANG="${WASI_SDK_PATH}/bin/clang"
F2C_BIN="${F2C}"

cat > "${MOCK_BIN}/gfortran" << GEOF
#!/bin/bash
# Fake gfortran: f2c + wasi-sdk clang wrapper

F2C_BIN="${F2C_BIN}"
REAL_CLANG="${REAL_CLANG}"
F2C_H="${F2C_H}"
WASI_SYSROOT="${WASI_SYSROOT}"
PY_INC="${CROSS_PREFIX}/include/python3.14"
WASM_TARGET="--target=wasm32-wasip1"

# Version detection
for a in "\$@"; do
  case "\$a" in
    --version|-dumpversion) echo "GNU Fortran (f2c/WASI) 13.0.0"; exit 0 ;;
  esac
done

# Parse args: separate Fortran files from compiler flags
COMPILE=0
OUTPUT=""
FORTRAN_FILES=()
PASS_ARGS=()

i=0
args=("\$@")
while [ \$i -lt \${#args[@]} ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -c) COMPILE=1 ;;
    -o) i=\$((i+1)); OUTPUT="\${args[\$i]}" ;;
    *.f|*.F|*.for|*.FOR|*.f90|*.F90) FORTRAN_FILES+=("\$a") ;;
    # Drop flags irrelevant/harmful to clang
    -frecursive|-fno-second-underscore|-fimplicit-none|-ffixed-form|-ffree-form) ;;
    -fno-underscoring|-funderscoring) ;;
    -Warray-temporaries|-Wconversion|-Wsurprising) ;;
    *) PASS_ARGS+=("\$a") ;;
  esac
  i=\$((i+1))
done

if [ \${#FORTRAN_FILES[@]} -eq 0 ]; then
  # Link-only invocation
  exec "\${REAL_CLANG}" "\${WASM_TARGET}" --sysroot="\${WASI_SYSROOT}" "\${PASS_ARGS[@]}" \${OUTPUT:+-o "\${OUTPUT}"}
fi

# Compile: f2c each .f file → .c, then compile .c with WASI clang
TMPDIR="\$(mktemp -d)"
trap "rm -rf \$TMPDIR" EXIT

C_FILES=()
for f in "\${FORTRAN_FILES[@]}"; do
  base="\$(basename "\${f%.*}")"
  cp "\$f" "\${TMPDIR}/\${base}.f"
  (cd "\${TMPDIR}" && "\${F2C_BIN}" -A -a "\${base}.f" 2>/dev/null) || \
  (cd "\${TMPDIR}" && "\${F2C_BIN}" "\${base}.f" 2>/dev/null) || true
  if [ -f "\${TMPDIR}/\${base}.c" ]; then
    C_FILES+=("\${TMPDIR}/\${base}.c")
  else
    echo "f2c: failed to convert \$f" >&2
    exit 1
  fi
done

exec "\${REAL_CLANG}" \${WASM_TARGET} \
  --sysroot="\${WASI_SYSROOT}" \
  -fPIC \
  -I"\$(dirname "\${F2C_H}")" \
  -I"\${PY_INC}" \
  -D__EMSCRIPTEN__=1 \
  -Wno-implicit-function-declaration \
  -Wno-return-type \
  \${COMPILE:+-c} \
  "\${PASS_ARGS[@]}" \
  "\${C_FILES[@]}" \
  \${OUTPUT:+-o "\${OUTPUT}"}
GEOF
chmod +x "${MOCK_BIN}/gfortran"

# Wrapper dir first so our clang wrapper takes precedence over wasi-sdk clang
export PATH="${WRAPPER_DIR}:${WASI_SDK_PATH}/bin:${MOCK_BIN}:${PATH}"

# ── Meson cross-file ──────────────────────────────────────────────────────────
HOST_PYTHON="$(which python3.14)"
HOST_CYTHON="$(which cython)"
# pybind11 pkgconfig dir (from pip-installed pybind11) — must be computed
# BEFORE the wasi-cross.ini heredoc that references ${PYBIND11_PC_DIR}.
PYBIND11_PC_DIR="$(python3.14 -c "import pybind11; import os; print(os.path.join(os.path.dirname(pybind11.__file__), 'share', 'pkgconfig'))" 2>/dev/null || echo "")"
echo ">>> pybind11 pkgconfig dir: ${PYBIND11_PC_DIR}"

cat > "${SCRIPT_DIR}/wasi-cross.ini" << EOF
[binaries]
c = '${WRAPPER_DIR}/clang'
cpp = '${WRAPPER_DIR}/clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
fortran = '${MOCK_BIN}/gfortran'
# Use HOST Python for meson's sysconfig introspection (WASI binary can't be
# exec'd on Linux). Compilation still targets wasm32-wasip1 via CFLAGS/CC.
python3 = '${HOST_PYTHON}'

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
# Point meson's host-machine pkg-config at pybind11's pkgconfig directory
pkg_config_libdir = ['${PYBIND11_PC_DIR}']

[host_machine]
# Declare as linux/wasm32: meson doesn't know 'wasi', and 'emscripten' requires
# emcc. With 'linux' meson can run the host Python for sysconfig queries while
# we supply the actual WASI clang via CC/CXX environment variables.
system = 'linux'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF

# Native file: tells meson which tools to use on the build (host Linux) machine
cat > "${SCRIPT_DIR}/native.ini" << EOF
[binaries]
python3 = '${HOST_PYTHON}'
cython = '${HOST_CYTHON}'
pkg-config = 'pkg-config'
EOF

# ── Cross-compile env vars ────────────────────────────────────────────────────
WASM_TARGET="--target=wasm32-wasip1"
PY_INC="${CROSS_PREFIX}/include/python3.14"
PY_LIB="${CROSS_PREFIX}/lib/libpython3.14.so"

export CC="${WRAPPER_DIR}/clang"
export CXX="${WRAPPER_DIR}/clang++"
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

# Unset WASI-specific vars so meson's host Python works correctly.
# _PYTHON_SYSCONFIGDATA_NAME breaks sysconfig → "missing distutils".
# PYTHONPATH= (empty string) adds '' to sys.path → "Empty module name".
# Use env -u to properly unset both variables for this invocation only.
env -u PYTHONPATH -u _PYTHON_SYSCONFIGDATA_NAME \
meson setup "${BUILD_DIR}" \
  --cross-file="${SCRIPT_DIR}/wasi-cross.ini" \
  --native-file="${SCRIPT_DIR}/native.ini" \
  --prefix="${INSTALL_DIR}" \
  -Dblas=none \
  -Dlapack=none \
  -Duse-pythran=false \
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
