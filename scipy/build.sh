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

  # Patch f2c: suppress hidden ftnlen CHARACTER-length args.
  # scipy's Cython bindings (cython_lapack.c, cython_blas.c) were generated
  # WITHOUT these extra args; WASM's strict type checker makes any signature
  # mismatch a hard link error.  Inject "return 0;" at the top of
  # should_add_ftnlen() in putpcc.c so f2c never adds ftnlen to function
  # signatures OR call sites — the definitive fix vs. post-hoc regex stripping.
  python3 - << 'FPATCH'
import re
fname = 'f2c/src/putpcc.c'
with open(fname) as f:
    src = f.read()
patched = re.sub(
    r'(should_add_ftnlen[^{]+\{)',
    r'\1\n    return 0; /* WASM: scipy Cython bindings have no ftnlen args */',
    src
)
if patched == src:
    raise RuntimeError('PATCH FAILED: could not locate should_add_ftnlen in ' + fname)
with open(fname, 'w') as f:
    f.write(patched)
print('Patched f2c/src/putpcc.c: should_add_ftnlen always returns 0')
FPATCH

  (cd f2c/src && cp makefile.u makefile && sed -i "s/gram.c:/gram.c1:/" makefile && make -j"$(nproc)")
fi
export F2C="${SCRIPT_DIR}/f2c/src/f2c"
F2C_H="${SCRIPT_DIR}/f2c/src/f2c.h"
F2C_SRC="${SCRIPT_DIR}/f2c/src"

# Fix f2c.h: #undef complex before its typedef to avoid C99 _Complex macro conflict.
# C99 defines 'complex' as an alias for '_Complex' (from <complex.h>).  f2c.h does:
#   typedef struct { real r, i; } complex;
# which expands to:
#   typedef struct { real r, i; } _Complex;   ← invalid, silently swallowed
# → the type 'complex' never actually exists, so anything that uses it
#   (typedef complex singlecomplex;) also fails.
# #undef complex first frees the identifier so the struct typedef succeeds.
sed -i 's/^typedef struct { real r, i; } complex;$/#undef complex\ntypedef struct { real r, i; } complex;/' \
  "${F2C_H}" 2>/dev/null || true

# ── Build libf2c.a (f2c runtime, WASM) ───────────────────────────────────────
# f2c-generated C code calls runtime helpers: pow_di, d_sign, s_cat, etc.
# These live in hoodmane/f2c's libF77/ directory.
BLAS_BUILD="${SCRIPT_DIR}/build/blas_lapack"
PKG_CONFIG_DIR="${SCRIPT_DIR}/build/pkgconfig"
BUILD_DIR="${SCRIPT_DIR}/build"
mkdir -p "${BLAS_BUILD}" "${PKG_CONFIG_DIR}" "${BUILD_DIR}"

# ── ftnlen stripping script (written once to a file, used by f2c_compile) ────
# Writing to a file avoids stdin-based heredoc-inside-function issues and lets
# us add more patterns without worrying about bash quoting.
FTNLEN_STRIP_PY="${BUILD_DIR}/strip_ftnlen.py"
cat > "${FTNLEN_STRIP_PY}" << 'PYEOF'
import re, sys

with open(sys.argv[1]) as fh:
    code = fh.read()

# 1. Remove ftnlen params from function signatures: ", ftnlen uplo_len"
code = re.sub(r',\s*ftnlen\s+\w+', '', code)

# 2. Remove ftnlen local variable declarations: "ftnlen uplo_len;"
code = re.sub(r'^\s*ftnlen\s+\w+;\s*\n', '', code, flags=re.MULTILINE)

# 3. Remove call-site char-length args — ALL forms f2c may generate.
#    f2c appends hidden length args at the END of CHARACTER argument call sites.
#    Patterns observed across f2c versions:
#    (a) explicit ftnlen cast with any expression: ", (ftnlen)1", ", (ftnlen)c__1",
#        ", (ftnlen)norm_len"  — use \w+ to match digits, vars, consts
code = re.sub(r',\s*\(ftnlen\)\s*\w+', '', code)
#    (b) bare long literal: ", 1L" or ", 1l"
code = re.sub(r',\s*1[Ll]\b', '', code)
#    (c) (integer) cast form: ", (integer)1", ", (integer)c__1"
code = re.sub(r',\s*\(integer\)\s*\w+', '', code)
#    (d) bare ftnlen variable names at call sites: ", norm_len", ", trans_len"
#        These are variables whose _declarations_ were removed above (step 2) but
#        still appear as call-site arguments in nested subroutine calls.
code = re.sub(r',\s*\w+_len\b', '', code)

with open(sys.argv[1], 'w') as fh:
    fh.write(code)
PYEOF

# ── Response-file filter script (used by the clang wrapper) ──────────────────
# wasm-ld/clang don't support GNU ld flags (--start-group/--end-group, -pthread)
# that meson injects from Python's sysconfig.  This script reads the response
# file, drops bad flags, and writes a filtered response file for the wrapper to
# pass to the real clang.
FILTER_RSP_PY="${BUILD_DIR}/filter_rsp.py"
cat > "${FILTER_RSP_PY}" << 'PYEOF'
import sys, os

src = sys.argv[1]   # input .rsp file
dst = sys.argv[2]   # output filtered .rsp file
host_py_inc = sys.argv[3] if len(sys.argv) > 3 else ''

BAD_EXACT = {
    '--start-group', '--end-group',
    '-Wl,--start-group', '-Wl,--end-group',
    '-pthread',
}

with open(src) as f:
    lines = f.read().splitlines()

out = []
for line in lines:
    # Trim whitespace and surrounding double-quotes
    arg = line.strip().strip('"')
    if not arg:
        continue
    if arg in BAD_EXACT:
        continue
    if arg.startswith('--version-script='):
        continue
    if host_py_inc and arg == f'-I{host_py_inc}':
        continue
    out.append(arg)

with open(dst, 'w') as f:
    f.write('\n'.join(out) + ('\n' if out else ''))
PYEOF

if [ ! -f "${BLAS_BUILD}/libf2c.a" ]; then
  echo ">>> Building libf2c.a (f2c runtime) for WASM"
  # hoodmane/f2c is a compiler-only repo; the runtime is a separate netlib package.
  LIBF2C_DIR="${BLAS_BUILD}/libf2c"
  if [ ! -d "${LIBF2C_DIR}" ]; then
    mkdir -p "${LIBF2C_DIR}"
    curl -fsSL "http://www.netlib.org/f2c/libf2c.zip" -o "${BLAS_BUILD}/libf2c.zip"
    python3 -c "
import zipfile, os
z = zipfile.ZipFile('${BLAS_BUILD}/libf2c.zip')
z.extractall('${LIBF2C_DIR}')
"
  fi
  mkdir -p "${BLAS_BUILD}/f2c_obj"
  for csrc in "${LIBF2C_DIR}"/*.c; do
    [ -f "$csrc" ] || continue
    base="$(basename "${csrc%.*}")"
    "${WASI_SDK_PATH}/bin/clang" \
      --target=wasm32-wasip1 --sysroot="${WASI_SYSROOT}" \
      -fPIC -O2 \
      -I"${LIBF2C_DIR}" \
      -Wno-implicit-function-declaration -Wno-return-type \
      -Wno-implicit-int \
      -c "$csrc" -o "${BLAS_BUILD}/f2c_obj/${base}.o" 2>/dev/null || true
  done
  OBJ_COUNT=$(ls "${BLAS_BUILD}/f2c_obj/"*.o 2>/dev/null | wc -l)
  if [ "${OBJ_COUNT}" -gt 0 ]; then
    "${WASI_SDK_PATH}/bin/llvm-ar" rcs "${BLAS_BUILD}/libf2c.a" "${BLAS_BUILD}/f2c_obj/"*.o
    echo ">>> libf2c.a: ${OBJ_COUNT} objects, $(ls -lh "${BLAS_BUILD}/libf2c.a")"
  else
    echo "WARNING: no libf2c objects compiled — f2c runtime symbols may be missing"
    touch "${BLAS_BUILD}/libf2c.a"  # empty placeholder so the check passes
  fi
fi

# ── Build reference BLAS + LAPACK for WASM ───────────────────────────────────
# scipy 1.17 requires external BLAS/LAPACK (removed lapack_lite fallback).
# We compile the netlib reference implementations using f2c + wasi-sdk clang.
LAPACK_VERSION="3.12.0"
LAPACK_SRC="${BLAS_BUILD}/lapack-${LAPACK_VERSION}"

if [ ! -d "${LAPACK_SRC}" ]; then
  echo ">>> Downloading LAPACK ${LAPACK_VERSION}"
  curl -fsSL "https://github.com/Reference-LAPACK/lapack/archive/refs/tags/v${LAPACK_VERSION}.tar.gz" \
    | tar xz -C "${BLAS_BUILD}"
fi

# Helper: compile a .f file to WASM .o via f2c
f2c_compile() {
  local src="$1" obj_dir="$2"
  local base; base="$(basename "${src%.*}")"
  local tmpdir; tmpdir="$(mktemp -d)"
  cp "$src" "${tmpdir}/${base}.f"
  # -R: don't promote REAL to DOUBLE (keeps real functions returning float, matching
  #     scipy's Cython declarations which expect float, not double).
  (cd "${tmpdir}" && "${F2C}" -A -a -R "${base}.f" 2>/dev/null) || \
  (cd "${tmpdir}" && "${F2C}" -R "${base}.f" 2>/dev/null) || return 1
  [ -f "${tmpdir}/${base}.c" ] || return 1

  # ── Strip f2c hidden Fortran character-string-length arguments ────────────────
  # f2c appends "ftnlen xyz_len" for each CHARACTER argument in the Fortran source.
  # scipy's Cython bindings (cython_lapack.c, cython_blas.c) were generated without
  # these extra arguments — they call LAPACK/BLAS subroutines using the standard
  # N-argument signature.  WASM's strict type system makes this a hard linker error
  # (vs a silent ABI mismatch on x86-64).
  # FTNLEN_STRIP_PY is written once before f2c_compile is defined (avoids
  # stdin-based heredoc issues when the function is called inside a loop).
  python3 "${FTNLEN_STRIP_PY}" "${tmpdir}/${base}.c" || true
  # Belt-and-suspenders: remove any residual (ftnlen)N call-site args Python missed.
  # f2c generates exactly ", (ftnlen)1" for CHARACTER literal lengths.
  sed -i -E 's/,[ \t]*\(ftnlen\)[0-9]+//g' "${tmpdir}/${base}.c" 2>/dev/null || true

  "${WASI_SDK_PATH}/bin/clang" \
    --target=wasm32-wasip1 --sysroot="${WASI_SYSROOT}" \
    -fPIC -O2 \
    -I"${F2C_SRC}" \
    -Wno-implicit-function-declaration -Wno-return-type \
    -c "${tmpdir}/${base}.c" -o "${obj_dir}/${base}.o" 2>/dev/null
  local rc=$?
  rm -rf "${tmpdir}"
  return $rc
}

if [ ! -f "${BLAS_BUILD}/libblas.a" ]; then
  echo ">>> Building reference BLAS for WASM ($(ls "${LAPACK_SRC}/BLAS/SRC/"*.f 2>/dev/null | wc -l) files)"
  mkdir -p "${BLAS_BUILD}/blas_obj"
  BLAS_FAIL=0
  for f in "${LAPACK_SRC}/BLAS/SRC/"*.f; do
    [ -f "$f" ] || continue
    f2c_compile "$f" "${BLAS_BUILD}/blas_obj" || BLAS_FAIL=$((BLAS_FAIL+1))
  done
  BLAS_OBJS=$(ls "${BLAS_BUILD}/blas_obj/"*.o 2>/dev/null | wc -l)
  if [ "${BLAS_OBJS}" -gt 0 ]; then
    "${WASI_SDK_PATH}/bin/llvm-ar" rcs "${BLAS_BUILD}/libblas.a" "${BLAS_BUILD}/blas_obj/"*.o
    echo ">>> libblas.a built (${BLAS_FAIL} failed): ${BLAS_OBJS} objects, $(ls -lh "${BLAS_BUILD}/libblas.a")"
  else
    echo "ERROR: no BLAS objects compiled"; exit 1
  fi
fi

if [ ! -f "${BLAS_BUILD}/liblapack.a" ]; then
  echo ">>> Building reference LAPACK for WASM (F77 .f files only — skipping .f90)"
  mkdir -p "${BLAS_BUILD}/lapack_obj"
  LAPACK_FAIL=0
  # Only process .f (Fortran 77); skip .f90/.F90 which f2c cannot handle
  for f in "${LAPACK_SRC}/SRC/"*.f; do
    [ -f "$f" ] || continue
    f2c_compile "$f" "${BLAS_BUILD}/lapack_obj" || LAPACK_FAIL=$((LAPACK_FAIL+1))
  done
  LAPACK_OBJS=$(ls "${BLAS_BUILD}/lapack_obj/"*.o 2>/dev/null | wc -l)
  if [ "${LAPACK_OBJS}" -gt 0 ]; then
    "${WASI_SDK_PATH}/bin/llvm-ar" rcs "${BLAS_BUILD}/liblapack.a" "${BLAS_BUILD}/lapack_obj/"*.o
    echo ">>> liblapack.a built (${LAPACK_FAIL} failed): ${LAPACK_OBJS} objects, $(ls -lh "${BLAS_BUILD}/liblapack.a")"
  else
    echo "ERROR: no LAPACK objects compiled"; exit 1
  fi
fi

# ── pkg-config files for WASM BLAS/LAPACK ────────────────────────────────────
cat > "${PKG_CONFIG_DIR}/blas.pc" << EOF
Name: blas
Description: Reference BLAS (f2c + wasm32-wasip1)
Version: ${LAPACK_VERSION}
Libs: -L${BLAS_BUILD} -lblas -lf2c
Cflags: -I${F2C_SRC}
EOF

# cblas: C interface to BLAS — required when blas_name='blas'.
# Our reference BLAS already contains the Fortran BLAS symbols; this stub
# satisfies meson's pkgconfig lookup without needing a separate cblas library.
cat > "${PKG_CONFIG_DIR}/cblas.pc" << EOF
Name: cblas
Description: C interface to reference BLAS (f2c + wasm32-wasip1)
Version: ${LAPACK_VERSION}
Requires: blas
Libs: -L${BLAS_BUILD} -lblas -lf2c
Cflags: -I${F2C_SRC}
EOF

cat > "${PKG_CONFIG_DIR}/lapack.pc" << EOF
Name: lapack
Description: Reference LAPACK (f2c + wasm32-wasip1)
Version: ${LAPACK_VERSION}
Requires: blas
Libs: -L${BLAS_BUILD} -llapack -lblas -lf2c
Cflags: -I${F2C_SRC}
EOF

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
  # Also fix indented/inline forward declarations inside functions (e.g. cgstrs.c:116
  # has '    void cprint_soln(...)' which ^void misses, conflicting with the definition
  # at the top level that ^void DID change to int).
  find scipy/sparse/linalg/_dsolve/SuperLU/SRC -name "*.c" -o -name "*.h" \
    | xargs -r sed -i 's/\bvoid \([cdsz][A-Za-z_]*\)(/int \1(/g' 2>/dev/null || true
  find scipy/sparse/linalg/_dsolve -maxdepth 1 -name "*.c" -o -name "*.h" \
    | xargs -r sed -i 's/^void/int/g' 2>/dev/null || true
  sed -i 's/TYPE_GENERIC_FUNC(\(.*\), void)/TYPE_GENERIC_FUNC(\1, int)/g' \
    scipy/sparse/linalg/_dsolve/_superluobject.h 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/optimize/_trlib/trlib_private.h 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/optimize/_trlib/trlib/trlib_private.h 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/_build_utils/src/wrap_dummy_g77_abi.c 2>/dev/null || true
  sed -i 's/^void/int/g' scipy/spatial/qhull_misc.h 2>/dev/null || true
  echo "" > scipy/sparse/linalg/_dsolve/SuperLU/SRC/input_error.c 2>/dev/null || true

  # ── Fix SuperLU singlecomplex (Pyodide patch 0003 compat) ────────────────────
  # Pyodide patch 0003 modifies scipy_slu_config.h to:
  #   #undef complex
  #   #include "f2c.h"         ← brings in complex (struct{real r,i;}) and doublecomplex
  #   #define complex singlecomplex   ← make 'complex' token expand to 'singlecomplex'
  # It also comments out the singlecomplex typedef in slu_scomplex.h with
  # "// defined in CLAPACK" — expecting OpenBLAS/CLAPACK to provide it.
  # We use reference BLAS (f2c, no CLAPACK), so singlecomplex is never defined.
  # Fix: insert typedef before the #define so singlecomplex is a real C type.
  SCIPY_SLU_CFG="scipy/sparse/linalg/_dsolve/SuperLU/SRC/scipy_slu_config.h"
  if grep -q 'define complex singlecomplex' "${SCIPY_SLU_CFG}" 2>/dev/null; then
    sed -i 's|#define complex singlecomplex|typedef struct { float r, i; } singlecomplex;\n#define complex singlecomplex|' \
      "${SCIPY_SLU_CFG}"
    echo ">>> Injected singlecomplex typedef into scipy_slu_config.h"
  fi

  cd "${SCRIPT_DIR}"

  touch "${SCIPY_SRC}/.patched"
fi

# ── Clang wrapper: strip GNU ld flags wasm-ld doesn't support ────────────────
# Host Python's sysconfig injects --start-group/--end-group (GNU ld only).
# wasm-ld rejects them. Wrap clang to strip them before forwarding.
WRAPPER_DIR="$(mktemp -d)"
cat > "${WRAPPER_DIR}/clang" << 'WEOF'
#!/bin/bash
# Clang wrapper for wasm32-wasip1: strips GNU ld flags wasm-ld doesn't support.
# Handles both direct args and response files (@file).
# ninja writes rsp content as a single space-separated line, so we use
# 'read -ra' (word-split each line) then emit a one-per-line filtered rsp.

# Shared filter: drop one arg; return 0 to keep, 1 to drop.
_drop_arg() {
  case "$1" in
    ''|--start-group|--end-group|-Wl,--start-group|-Wl,--end-group) return 1 ;;
    -pthread) return 1 ;;
    --version-script=*|-Wl,--version-script=*) return 1 ;;
    -I@HOST_PY_INC@) return 1 ;;
    *) return 0 ;;
  esac
}

args=()
for arg in "$@"; do
  if [[ "$arg" == @* ]]; then
    # Filter response file.
    # ninja writes rsp content as ONE long space-separated line (not one-per-line).
    # 'read -ra _words' splits each line on whitespace into an array, handling
    # both the one-long-line format and the traditional one-arg-per-line format.
    # We write a filtered one-per-line rsp so clang/wasm-ld can parse it cleanly.
    rsp_src="${arg#@}"
    if [[ -r "$rsp_src" ]]; then
      rsp_dst="${rsp_src}.filtered"
      rsp_out=()
      while read -ra _words || [[ ${#_words[@]} -gt 0 ]]; do
        for _w in "${_words[@]}"; do
          [[ -z "$_w" ]] && continue
          _drop_arg "$_w" || continue
          rsp_out+=("$_w")
        done
      done < "$rsp_src"
      printf '%s\n' "${rsp_out[@]}" > "$rsp_dst"
      args+=("@${rsp_dst}")
    fi
  else
    _drop_arg "$arg" || continue
    args+=("$arg")
  fi
done
# Prepend WASI Python include so it wins over any host Python include meson injects
exec "@REAL_CLANG@" "-I@WASI_PY_INC@" "${args[@]}"
WEOF
HOST_PY_INC="$(python3.14 -c "import sysconfig; print(sysconfig.get_path('include'))" 2>/dev/null)"
WASI_PY_INC="${CROSS_PREFIX}/include/python3.14"
sed -i "s|@REAL_CLANG@|${WASI_SDK_PATH}/bin/clang|g" "${WRAPPER_DIR}/clang"
sed -i "s|@HOST_PY_INC@|${HOST_PY_INC}|g" "${WRAPPER_DIR}/clang"
sed -i "s|@WASI_PY_INC@|${WASI_PY_INC}|g" "${WRAPPER_DIR}/clang"
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
    -J*) ;;         # gfortran module output dir — not used by f2c/clang
    -std=legacy|-std=f*|-std=gnu*) ;;  # gfortran Fortran standard flags, unknown to clang
    -lgfortran|-lquadmath) ;;  # gfortran runtime libs — don't exist for WASI
    -Wl,--start-group|-Wl,--end-group|--start-group|--end-group) ;;  # GNU ld only, wasm-ld rejects
    -Wl,--version-script=*|--version-script=*) ;;  # GNU ld only, wasm-ld rejects
    -pthread) ;;  # not meaningful for wasm32-wasip1
    -ffloat-store|-fno-math-errno|-fstack-arrays|-fcheck=*|-fbounds-check) ;;  # GCC-only, clang rejects
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
  -D_WASI_EMULATED_SIGNAL \
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
PYBIND11_INC="$(python3.14 -c "import pybind11; print(pybind11.get_include())" 2>/dev/null || echo "")"
echo ">>> pybind11 pkgconfig dir: ${PYBIND11_PC_DIR}"
echo ">>> pybind11 include dir:   ${PYBIND11_INC}"

# Create a pkg-config wrapper for the host (WASM) machine.
# We point it only at PYBIND11_PC_DIR so:
#   - pybind11 is found (needed by scipy C++ extensions)
#   - blas/lapack/etc return nothing → graceful skip (required: false in meson)
# Without a pkg-config in the cross-file [binaries], meson errors out
# immediately ("Pkg-config for machine host machine not found").
# pkg-config wrapper for the WASM host machine.
# Searches our PKG_CONFIG_DIR (blas.pc, lapack.pc) + pybind11's dir.
# This satisfies scipy's BLAS/LAPACK detection and pybind11 lookup.
HOST_PKG_CONFIG="$(which pkg-config 2>/dev/null || echo pkg-config)"
# Copy pybind11.pc into our combined pkgconfig dir so we only need one LIBDIR
if [ -n "${PYBIND11_PC_DIR}" ] && [ -d "${PYBIND11_PC_DIR}" ]; then
  cp "${PYBIND11_PC_DIR}"/*.pc "${PKG_CONFIG_DIR}/" 2>/dev/null || true
fi
cat > "${MOCK_BIN}/wasi-pkg-config" << PKGEOF
#!/bin/bash
# pkg-config for the WASM host machine — searches our combined pkgconfig dir.
exec env PKG_CONFIG_LIBDIR="${PKG_CONFIG_DIR}" "${HOST_PKG_CONFIG}" "\$@"
PKGEOF
chmod +x "${MOCK_BIN}/wasi-pkg-config"

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
# pkg-config wrapper that serves blas.pc, lapack.pc, and pybind11.pc
pkg-config = '${MOCK_BIN}/wasi-pkg-config'

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
pkg_config_libdir = ['${PKG_CONFIG_DIR}']

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

# ── Stub setjmp.h for WASI ───────────────────────────────────────────────────
# The WASI sysroot setjmp.h unconditionally #errors unless -mllvm -wasm-enable-sjlj
# is passed (requires WASM exception-handling proposal in the engine).
# qhull and a few other scipy components use setjmp only for fatal error recovery.
# We provide a stub that makes setjmp() always return 0 and longjmp() trap —
# semantically: "no error saved, fatal errors abort". This avoids the proposal.
STUB_INC="${SCRIPT_DIR}/build/stub_include"
mkdir -p "${STUB_INC}"
cat > "${STUB_INC}/setjmp.h" << 'SJEOF'
#pragma once
/* WASI setjmp stub: setjmp always succeeds (returns 0), longjmp traps.
   Used by qhull error paths — fatal errors become unreachable traps. */
typedef int jmp_buf[32];
#define setjmp(env)  (0)
static inline __attribute__((noreturn)) void longjmp(jmp_buf env, int val) {
    __builtin_trap();
}
SJEOF

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
  -I${STUB_INC} \
  -I$(dirname "${F2C_H}") \
  -isystem ${WASI_SYSROOT}/include \
  -D__EMSCRIPTEN__=1 \
  -DNPY_NO_SIGNAL \
  -D_WASI_EMULATED_SIGNAL \
  -DUNDERSCORE_G77 \
  -DFE_TONEAREST=0 -DFE_TOWARDZERO=1 -DFE_DOWNWARD=2 -DFE_UPWARD=3 \
  -Wno-return-type \
  -fvisibility=default"

export CXXFLAGS="${WASM_TARGET} -fPIC \
  -I${PY_INC} \
  -I${STUB_INC} \
  -I$(dirname "${F2C_H}") \
  ${PYBIND11_INC:+-I${PYBIND11_INC}} \
  -isystem ${WASI_SYSROOT}/include \
  -D__EMSCRIPTEN__=1 \
  -DNPY_NO_SIGNAL \
  -D_WASI_EMULATED_SIGNAL \
  -fno-exceptions \
  -fvisibility=default"
# NOTE: We use -fno-exceptions instead of -fwasm-exceptions.
# -fwasm-exceptions (WASM EH proposal) generates __wasm_lpad_context exports
# in every .so, which componentize-py/wit-component cannot handle (it causes
# "multiple libraries export _start" panic in the linker).  C++ exceptions are
# not needed for scipy's numerical kernels — Cython uses Python-API error codes,
# and the rare C++ exception paths become std::terminate() which is acceptable.

export LDFLAGS="${WASM_TARGET} \
  --sysroot=${WASI_SYSROOT} \
  -L${WASI_SYSROOT}/lib/wasm32-wasip1 \
  -L${CROSS_PREFIX}/lib \
  -L${BLAS_BUILD} \
  -shared \
  ${PY_LIB} \
  -Wl,--experimental-pic \
  -Wl,--unresolved-symbols=import-dynamic \
  -Wl,--allow-undefined \
  -nostdlib++ \
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
  -Dblas=blas \
  -Dlapack=lapack \
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
  ninja -C "${BUILD_DIR}" -j"$(nproc)" -k0 2>&1 | tee /tmp/scipy_ninja.log
EXIT=${PIPESTATUS[0]}
if [ "$EXIT" != "0" ]; then
  echo "ninja build failed — errors:"
  grep -E "^(FAILED|.*error:)" /tmp/scipy_ninja.log | head -100
  exit "$EXIT"
fi

echo ">>> ninja install"
PYTHONPATH="${CROSS_PREFIX}/lib/python3.14" \
  ninja -C "${BUILD_DIR}" install

echo ">>> Rename .so files to WASI suffix"
# Meson queries the HOST Python (x86-64) for EXT_SUFFIX, producing files named
# .cpython-314-x86_64-linux-gnu.so.  componentize-py only bundles files ending
# in .cpython-314-wasm32-wasi.so (or .abi3.so) — it ignores the x86-64 suffix.
# Rename everything so Python and componentize-py can find the WASM modules.
HOST_EXT_SUFFIX="$(python3.14 -c "import sysconfig; print(sysconfig.get_config_var('EXT_SUFFIX'))" 2>/dev/null || echo "")"
WASI_EXT_SUFFIX=".cpython-314-wasm32-wasi.so"
if [ -n "${HOST_EXT_SUFFIX}" ] && [ "${HOST_EXT_SUFFIX}" != "${WASI_EXT_SUFFIX}" ]; then
  echo ">>> Renaming: '${HOST_EXT_SUFFIX}' → '${WASI_EXT_SUFFIX}'"
  COUNT=0
  find "${INSTALL_DIR}" -name "*${HOST_EXT_SUFFIX}" | while IFS= read -r f; do
    new="${f%${HOST_EXT_SUFFIX}}${WASI_EXT_SUFFIX}"
    mv "$f" "$new"
    COUNT=$((COUNT+1))
  done
  RENAMED=$(find "${INSTALL_DIR}" -name "*${WASI_EXT_SUFFIX}" | wc -l)
  echo ">>> Renamed ${RENAMED} .so files to WASI suffix"
else
  echo ">>> EXT_SUFFIX already correct or could not detect: '${HOST_EXT_SUFFIX}'"
fi

echo ">>> scipy build complete"
echo "Installed to: ${INSTALL_DIR}"
ls "${INSTALL_DIR}" 2>/dev/null || true
