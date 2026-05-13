#!/bin/bash
# Build Pillow 9.5.0 for wasm32-wasip1 (PNG-only, zlib-only build)
# Version matrix:
#   9.5.0  ✓  jpeg optional, setup.py + --disable-X flags work
#   10.x   ✗  jpeg became a required dependency
#   11.x   ✗  --disable-X CLI flags removed from setup.py
#   12.x   ✗  pil_imaging_mode internal library (build_clib skipped in cross-compile)

set -eou pipefail

WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
# Install PIC-compiled zlib into a local dir, NOT the wasi-sysroot.
# The wasi-sdk is cached by CI; writing to the sysroot would persist a
# non-PIC libz.a across runs.  A local dir is always rebuilt fresh.
ZLIB_PREFIX="$(pwd)/zlib-pic-install"

PILLOW_VERSION="9.5.0"
PILLOW_SRC="Pillow-${PILLOW_VERSION}"

if [ ! -e venv ]; then
  python3.14 -m venv venv
fi
. venv/bin/activate
pip install wheel setuptools

# ── Step 1: cross-compile zlib for wasm32-wasip1 ──────────────────────────────
if [ ! -f "${ZLIB_PREFIX}/lib/libz.a" ]; then
  echo ">>> Building zlib for wasm32-wasip1"
  ZLIB_VERSION="1.3.1"
  [ -f "zlib-${ZLIB_VERSION}.tar.gz" ] || \
    curl -fsSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
      -o "zlib-${ZLIB_VERSION}.tar.gz"
  tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
  (
    cd "zlib-${ZLIB_VERSION}"
    CC="${WASI_SDK_PATH}/bin/clang" \
    CFLAGS="--target=wasm32-wasip1 --sysroot=${WASI_SYSROOT} -fPIC" \
    ./configure --prefix="${ZLIB_PREFIX}" --static
    make -j"$(nproc)"
    make install
  )
  echo ">>> zlib installed to ${ZLIB_PREFIX}"
fi

# ── Step 2: download Pillow source ────────────────────────────────────────────
if [ ! -d "${PILLOW_SRC}" ]; then
  [ -f "${PILLOW_SRC}.tar.gz" ] || \
    curl -fsSL "https://files.pythonhosted.org/packages/00/d5/4903f310765e0ff2b8e91ffe55031ac6af77d982f0156061e20a4d1a8b2d/Pillow-9.5.0.tar.gz" \
      -o "${PILLOW_SRC}.tar.gz"
  tar xzf "${PILLOW_SRC}.tar.gz"
fi

# ── Step 3: patch setup.py for Python 3.13+ exec()/locals() semantics ────────
# Python 3.13+ no longer populates locals() from exec() in function scope.
# Pillow 9.5.0's get_version() does exactly this → KeyError: '__version__'
python3 - <<'PYEOF'
import re, sys
path = "setup.py"
src = open(path).read()
# Replace:  return locals()["__version__"]
# With:     exec into explicit dict
patched = src.replace(
    'return locals()["__version__"]',
    '_ns = {}; exec(open("src/PIL/_version.py").read(), _ns); return _ns["__version__"]'
)
if patched == src:
    print("WARNING: get_version patch not applied — pattern not found", file=sys.stderr)
else:
    open(path, "w").write(patched)
    print("Patched setup.py get_version() for Python 3.13+ compatibility")
PYEOF

# ── Step 5: clang wrapper that strips host include paths ──────────────────────
# setuptools/distutils always appends -I/usr/include and -I/usr/local/include
# from the host Python's sysconfig, regardless of DISABLE_PLATFORM_GUESSING.
# These leak Linux-specific headers into the WASI cross-compile.
# The wrapper filters them out before calling the real clang.
WRAPPER_DIR="$(mktemp -d)"
REAL_CLANG="${WASI_SDK_PATH}/bin/clang"
REAL_CLANGXX="${WASI_SDK_PATH}/bin/clang++"

cat > "${WRAPPER_DIR}/clang" <<'WRAPPER'
#!/bin/bash
args=()
for arg in "$@"; do
  case "$arg" in
    -I/usr/include|-I/usr/include/*|-I/usr/local/include|-I/usr/local/include/*)
      ;; # drop host include paths
    *)
      args+=("$arg") ;;
  esac
done
exec "@REAL_CLANG@" "${args[@]}"
WRAPPER
sed -i "s|@REAL_CLANG@|${REAL_CLANG}|g" "${WRAPPER_DIR}/clang"
chmod +x "${WRAPPER_DIR}/clang"

cp "${WRAPPER_DIR}/clang" "${WRAPPER_DIR}/clang++"
sed -i "s|${REAL_CLANG}|${REAL_CLANGXX}|g" "${WRAPPER_DIR}/clang++"
chmod +x "${WRAPPER_DIR}/clang++"

# ── Step 6: build Pillow (PNG/zlib only, all other formats disabled) ──────────
cd "${PILLOW_SRC}"

export CC="${WRAPPER_DIR}/clang"
export CXX="${WRAPPER_DIR}/clang++"
export AR="${WASI_SDK_PATH}/bin/llvm-ar"
export RANLIB="${WASI_SDK_PATH}/bin/llvm-ranlib"
export STRIP="${WASI_SDK_PATH}/bin/llvm-strip"

export CFLAGS="--target=wasm32-wasip1 --sysroot=${WASI_SYSROOT} \
  -isystem ${WASI_SYSROOT}/include \
  -isystem ${WASI_SYSROOT}/include/wasm32-wasip1 \
  -I${CROSS_PREFIX}/include/python3.14 \
  -D__EMSCRIPTEN__=1 \
  -fPIC"

export LDFLAGS="--target=wasm32-wasip1 \
  --sysroot=${WASI_SYSROOT} \
  -L${ZLIB_PREFIX}/lib \
  -L${WASI_SYSROOT}/lib/wasm32-wasip1 \
  -L${CROSS_PREFIX}/lib \
  ${CROSS_PREFIX}/lib/libpython3.14.so \
  -Wl,--experimental-pic \
  -Wl,--shared \
  -Wl,--unresolved-symbols=import-dynamic"

export LDSHARED="${WRAPPER_DIR}/clang"

# Tell Pillow where to find the PIC-compiled zlib
export ZLIB_ROOT="${ZLIB_PREFIX}"

# Critical: prevent Pillow from searching /usr/include, /usr/lib, etc.
export DISABLE_PLATFORM_GUESSING=1

export PYTHONPATH="${CROSS_PREFIX}/lib/python3.14"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi

# DISABLE_PLATFORM_GUESSING=1 (set above) is sufficient: Pillow will only find
# libraries whose ROOT env var is explicitly set.  We only set ZLIB_ROOT, so
# all other optional features (jpeg, tiff, webp, freetype …) are auto-skipped.
# The --disable-X CLI flags were removed/broken in newer setuptools versions.
python3 setup.py build_ext --plat-name wasm32-wasip1
python3 setup.py bdist_wheel --plat-name wasm32-wasip1

wheel unpack --dest build dist/pillow-*.whl 2>/dev/null || wheel unpack --dest build dist/Pillow-*.whl
