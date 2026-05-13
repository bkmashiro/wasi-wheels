#!/bin/bash
# Build Pillow 9.5.0 for wasm32-wasip1 (zlib + jpeg)
# jpeg became required in Pillow 9.1.0, so we cross-compile libjpeg-turbo too.
# cmake is used for libjpeg-turbo (with SIMD disabled for WASM compatibility).

set -eou pipefail

WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
# Local install dirs (not the cached wasi-sysroot) so rebuilds always get -fPIC
DEPS_PREFIX="$(pwd)/wasi-deps"

PILLOW_VERSION="9.5.0"
PILLOW_SRC="Pillow-${PILLOW_VERSION}"

if [ ! -e venv ]; then
  python3.14 -m venv venv
fi
. venv/bin/activate
pip install wheel setuptools

WASI_CFLAGS="--target=wasm32-wasip1 --sysroot=${WASI_SYSROOT} -fPIC"

# ── Step 1: cross-compile zlib ────────────────────────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libz.a" ]; then
  echo ">>> Building zlib for wasm32-wasip1"
  ZLIB_VERSION="1.3.1"
  [ -f "zlib-${ZLIB_VERSION}.tar.gz" ] || \
    curl -fsSL "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
      -o "zlib-${ZLIB_VERSION}.tar.gz"
  tar xzf "zlib-${ZLIB_VERSION}.tar.gz"
  (
    cd "zlib-${ZLIB_VERSION}"
    CC="${WASI_SDK_PATH}/bin/clang" \
    CFLAGS="${WASI_CFLAGS}" \
    ./configure --prefix="${DEPS_PREFIX}" --static
    make -j"$(nproc)"
    make install
  )
  echo ">>> zlib installed to ${DEPS_PREFIX}"
fi

# ── Step 2: cross-compile libjpeg-turbo ──────────────────────────────────────
if [ ! -f "${DEPS_PREFIX}/lib/libjpeg.a" ]; then
  echo ">>> Building libjpeg-turbo for wasm32-wasip1"
  JPEG_VERSION="2.1.5.1"
  [ -f "libjpeg-turbo-${JPEG_VERSION}.tar.gz" ] || \
    curl -fsSL "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_VERSION}/libjpeg-turbo-${JPEG_VERSION}.tar.gz" \
      -o "libjpeg-turbo-${JPEG_VERSION}.tar.gz"
  tar xzf "libjpeg-turbo-${JPEG_VERSION}.tar.gz"
  mkdir -p libjpeg-turbo-${JPEG_VERSION}/build-wasi
  (
    cd "libjpeg-turbo-${JPEG_VERSION}/build-wasi"
    cmake .. \
      -DCMAKE_C_COMPILER="${WASI_SDK_PATH}/bin/clang" \
      -DCMAKE_C_FLAGS="${WASI_CFLAGS}" \
      -DCMAKE_SYSTEM_NAME=Generic \
      -DCMAKE_SYSTEM_PROCESSOR=wasm32 \
      -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
      -DWITH_SIMD=FALSE \
      -DWITH_JPEG8=1 \
      -DENABLE_SHARED=FALSE \
      -DENABLE_STATIC=TRUE \
      -DCMAKE_BUILD_TYPE=Release
    make -j"$(nproc)"
    make install
  )
  echo ">>> libjpeg-turbo installed to ${DEPS_PREFIX}"
fi

# ── Step 3: download Pillow source ────────────────────────────────────────────
if [ ! -d "${PILLOW_SRC}" ]; then
  [ -f "${PILLOW_SRC}.tar.gz" ] || \
    curl -fsSL "https://files.pythonhosted.org/packages/00/d5/4903f310765e0ff2b8e91ffe55031ac6af77d982f0156061e20a4d1a8b2d/Pillow-9.5.0.tar.gz" \
      -o "${PILLOW_SRC}.tar.gz"
  tar xzf "${PILLOW_SRC}.tar.gz"
fi

# ── Step 4: clang wrapper that strips host include paths ──────────────────────
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

# ── Step 5: build Pillow ──────────────────────────────────────────────────────
cd "${PILLOW_SRC}"

# Patch setup.py for Python 3.13+ exec()/locals() semantics.
python3 - <<'PYEOF'
import sys
path = "setup.py"
src = open(path).read()
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
  -L${DEPS_PREFIX}/lib \
  -L${WASI_SYSROOT}/lib/wasm32-wasip1 \
  -L${CROSS_PREFIX}/lib \
  ${CROSS_PREFIX}/lib/libpython3.14.so \
  -Wl,--experimental-pic \
  -Wl,--shared \
  -Wl,--unresolved-symbols=import-dynamic"

export LDSHARED="${WRAPPER_DIR}/clang"

export ZLIB_ROOT="${DEPS_PREFIX}"
export JPEG_ROOT="${DEPS_PREFIX}"

# DISABLE_PLATFORM_GUESSING prevents searching /usr/include, /usr/lib, etc.
# Only ZLIB_ROOT and JPEG_ROOT are set; all other features auto-skip.
export DISABLE_PLATFORM_GUESSING=1

export PYTHONPATH="${CROSS_PREFIX}/lib/python3.14"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi

python3 setup.py build_ext --plat-name wasm32-wasip1
python3 setup.py bdist_wheel --plat-name wasm32-wasip1

wheel unpack --dest build dist/pillow-*.whl 2>/dev/null || wheel unpack --dest build dist/Pillow-*.whl
