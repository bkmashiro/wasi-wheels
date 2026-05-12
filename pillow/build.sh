#!/bin/bash
# Build Pillow 12.x for wasm32-wasip1 (PNG-only, zlib-only build)
# PNG support in Pillow uses zlib's inflate() directly (ZipDecode.c) — no libpng needed.

set -eou pipefail

WASI_SYSROOT="${WASI_SDK_PATH}/share/wasi-sysroot"
WASI_CC="${WASI_SDK_PATH}/bin/clang --sysroot=${WASI_SYSROOT}"
ZLIB_PREFIX="${WASI_SYSROOT}"  # install zlib into sysroot so Pillow finds it

PILLOW_VERSION="12.2.0"
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
    curl -fsSL "https://files.pythonhosted.org/packages/8c/21/c2bcdd5906101a30244eaffc1b6e6ce71a31bd0742a01eb89e660ebfac2d/pillow-12.2.0.tar.gz" \
      -o "${PILLOW_SRC}.tar.gz"
  tar xzf "${PILLOW_SRC}.tar.gz"
fi

# ── Step 3: build Pillow (PNG/zlib only, all other formats disabled) ──────────
cd "${PILLOW_SRC}"

export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"
export AR="${WASI_SDK_PATH}/bin/llvm-ar"
export RANLIB="${WASI_SDK_PATH}/bin/llvm-ranlib"
export STRIP="${WASI_SDK_PATH}/bin/llvm-strip"

export CFLAGS="--target=wasm32-wasip1 --sysroot=${WASI_SYSROOT} \
  -I${WASI_SYSROOT}/include \
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

export LDSHARED="${WASI_SDK_PATH}/bin/clang"

# Tell Pillow where to find zlib (points at the wasi sysroot)
export ZLIB_ROOT="${WASI_SYSROOT}"

# Critical: prevent Pillow from searching /usr/include, /usr/lib, etc.
export DISABLE_PLATFORM_GUESSING=1

export PYTHONPATH="${CROSS_PREFIX}/lib/python3.14"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__wasi_wasm32-wasi

python3 setup.py build_ext \
  --plat-name wasm32-wasip1 \
  -C pillow-configuration=jpeg=disable \
  -C pillow-configuration=tiff=disable \
  -C pillow-configuration=webp=disable \
  -C pillow-configuration=jpeg2000=disable \
  -C pillow-configuration=imagequant=disable \
  -C pillow-configuration=xcb=disable \
  -C pillow-configuration=avif=disable \
  -C pillow-configuration=freetype=disable \
  -C pillow-configuration=lcms=disable \
  -C pillow-configuration=raqm=disable

python3 setup.py bdist_wheel \
  --plat-name wasm32-wasip1 \
  -C pillow-configuration=jpeg=disable \
  -C pillow-configuration=tiff=disable \
  -C pillow-configuration=webp=disable \
  -C pillow-configuration=jpeg2000=disable \
  -C pillow-configuration=imagequant=disable \
  -C pillow-configuration=xcb=disable \
  -C pillow-configuration=avif=disable \
  -C pillow-configuration=freetype=disable \
  -C pillow-configuration=lcms=disable \
  -C pillow-configuration=raqm=disable

wheel unpack --dest build dist/pillow-*.whl 2>/dev/null || wheel unpack --dest build dist/Pillow-*.whl
