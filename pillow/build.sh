#!/bin/bash
# Build Pillow 11.x for wasm32-wasip1 (PNG-only, zlib-only build)
# Using 11.x instead of 12.x to avoid the pil_imaging_mode static library
# introduced in 12.0 whose build_clib step is skipped in cross-compile contexts.

set -eou pipefail

WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
ZLIB_PREFIX="${WASI_SYSROOT}"  # install zlib into sysroot so Pillow finds it

PILLOW_VERSION="11.1.0"
PILLOW_SRC="pillow-${PILLOW_VERSION}"

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
    CFLAGS="--target=wasm32-wasip1 --sysroot=${WASI_SYSROOT}" \
    ./configure --prefix="${ZLIB_PREFIX}" --static
    make -j"$(nproc)"
    make install
  )
  echo ">>> zlib installed to ${ZLIB_PREFIX}"
fi

# ── Step 2: download Pillow source ────────────────────────────────────────────
if [ ! -d "${PILLOW_SRC}" ]; then
  [ -f "${PILLOW_SRC}.tar.gz" ] || \
    curl -fsSL "https://files.pythonhosted.org/packages/f3/af/c097e544e7bd278333db77933e535098c259609c4eb3b85381109602fb5b/pillow-11.1.0.tar.gz" \
      -o "${PILLOW_SRC}.tar.gz"
  tar xzf "${PILLOW_SRC}.tar.gz"
fi

# ── Step 3: clang wrapper that strips host include paths ──────────────────────
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

# ── Step 4: build Pillow (PNG/zlib only, all other formats disabled) ──────────
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
  -L${WASI_SYSROOT}/lib/wasm32-wasip1 \
  -L${CROSS_PREFIX}/lib \
  ${CROSS_PREFIX}/lib/libpython3.14.so \
  -Wl,--experimental-pic \
  -Wl,--shared \
  -Wl,--unresolved-symbols=import-dynamic"

export LDSHARED="${WRAPPER_DIR}/clang"

# Tell Pillow where to find zlib (points at the wasi sysroot)
export ZLIB_ROOT="${WASI_SYSROOT}"

# Critical: prevent Pillow from searching /usr/include, /usr/lib, etc.
export DISABLE_PLATFORM_GUESSING=1

export PYTHONPATH="${CROSS_PREFIX}/lib/python3.14"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi

DISABLE_FLAGS="--disable-jpeg --disable-tiff --disable-webp --disable-jpeg2000 \
  --disable-imagequant --disable-xcb --disable-freetype \
  --disable-lcms --disable-raqm"

python3 setup.py build_ext --plat-name wasm32-wasip1 $DISABLE_FLAGS
python3 setup.py bdist_wheel --plat-name wasm32-wasip1 $DISABLE_FLAGS

wheel unpack --dest build dist/pillow-*.whl 2>/dev/null || wheel unpack --dest build dist/Pillow-*.whl
