#!/bin/bash

set -eou pipefail

if [ ! -e venv ]; then
  python3.14 -m venv venv
fi

. venv/bin/activate
pip install build expandvars wheel setuptools

curl -sL -O https://patch-diff.githubusercontent.com/raw/aio-libs/multidict/pull/929.patch

pushd src
patch -p1 <../929.patch
popd

ARCH_TRIPLET=_wasi_wasm32-wasi

export CC="${WASI_SDK_PATH}/bin/clang"
export CXX="${WASI_SDK_PATH}/bin/clang++"

export PYTHONPATH=$CROSS_PREFIX/lib/python3.14

export CFLAGS="-I${CROSS_PREFIX}/include/python3.14 -D__EMSCRIPTEN__=1"
export CXXFLAGS="-I${CROSS_PREFIX}/include/python3.14"
export LDSHARED=${CC}
export AR="${WASI_SDK_PATH}/bin/ar"
export RANLIB=true
export LDFLAGS="-shared"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata_${ARCH_TRIPLET}

cd src
python3 -m build -n -w
wheel unpack --dest build dist/*.whl 
git checkout .
