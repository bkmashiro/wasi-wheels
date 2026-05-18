BUILD_DIR := $(abspath build)
WASI_SDK := $(BUILD_DIR)/wasi-sdk
CPYTHON_SRC := $(BUILD_DIR)/cpython-src
CPYTHON_HOST := $(BUILD_DIR)/cpython-host
CPYTHON := $(BUILD_DIR)/cpython-wasi/install
SYSCONFIG := $(BUILD_DIR)/cpython-wasi/build/lib.wasi-wasm32-3.14
OUTPUTS := \
	$(BUILD_DIR)/numpy-wasi.tar.gz \
	$(BUILD_DIR)/numpy-static-wasi.tar.gz \
	$(BUILD_DIR)/pydantic_core-wasi.tar.gz \
	$(BUILD_DIR)/regex-wasi.tar.gz \
	$(BUILD_DIR)/tiktoken-wasi.tar.gz \
	$(BUILD_DIR)/Pillow-wasi.tar.gz \
	$(BUILD_DIR)/cpython-3.14-wasi.tar.gz

# Disabled (require WASI-incompatible deps or not needed for eval functions):
#	$(BUILD_DIR)/scipy-wasi.tar.gz \
#	$(BUILD_DIR)/pandas-wasi.tar.gz \
#	$(BUILD_DIR)/aiohttp-wasi.tar.gz \
#	$(BUILD_DIR)/charset_normalizer-wasi.tar.gz \
#	$(BUILD_DIR)/frozenlist-wasi.tar.gz \
#	$(BUILD_DIR)/multidict-wasi.tar.gz \
#	$(BUILD_DIR)/sqlalchemy-wasi.tar.gz \
#	$(BUILD_DIR)/tiktoken-wasi.tar.gz \
#	$(BUILD_DIR)/tiktoken_ext-wasi.tar.gz \
#	$(BUILD_DIR)/wrapt-wasi.tar.gz \
#	$(BUILD_DIR)/yaml-wasi.tar.gz \
#	$(BUILD_DIR)/_yaml-wasi.tar.gz \
#	$(BUILD_DIR)/yarl-wasi.tar.gz

WASI_SDK_VERSION := 33
CPYTHON_VERSION := 3.14.0
CPYTHON_TARBALL := Python-$(CPYTHON_VERSION).tgz
CPYTHON_URL := https://www.python.org/ftp/python/$(CPYTHON_VERSION)/$(CPYTHON_TARBALL)

HOST_OS := $(shell uname -s | sed -e 's/Darwin/macos/' -e 's/Linux/linux/')
# wasi-sdk-33 Linux release uses "arm64" for aarch64 and "x86_64" for x86_64
HOST_ARCH := $(shell uname -m | sed -e 's/aarch64/arm64/')

PYO3_CROSS_LIB_DIR := $(SYSCONFIG)

.PHONY: all prerequisites numpy numpy-static pydantic regex tiktoken pillow cpython-tarball
all: $(OUTPUTS)

# Convenience phony aliases for CI steps (avoids absolute-path issues with $(abspath))
prerequisites: $(WASI_SDK) $(CPYTHON)
numpy: $(BUILD_DIR)/numpy-wasi.tar.gz
numpy-static: $(BUILD_DIR)/numpy-static-wasi.tar.gz
pydantic: $(BUILD_DIR)/pydantic_core-wasi.tar.gz
regex: $(BUILD_DIR)/regex-wasi.tar.gz
tiktoken: $(BUILD_DIR)/tiktoken-wasi.tar.gz
pillow: $(BUILD_DIR)/Pillow-wasi.tar.gz
cpython-tarball: $(BUILD_DIR)/cpython-3.14-wasi.tar.gz

$(OUTPUTS): $(WASI_SDK) $(CPYTHON)

$(BUILD_DIR)/aiohttp-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd aiohttp && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a aiohttp/src/build/*/aiohttp "$(@D)"
	(cd "$(@D)" && tar czf aiohttp-wasi.tar.gz aiohttp)

$(BUILD_DIR)/charset_normalizer-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd charset_normalizer && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a charset_normalizer/src/build/lib.*/charset_normalizer "$(@D)"
	(cd "$(@D)" && tar czf charset_normalizer-wasi.tar.gz charset_normalizer)

$(BUILD_DIR)/frozenlist-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd frozenlist && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a frozenlist/src/build/lib.*/frozenlist "$(@D)"
	(cd "$(@D)" && tar czf frozenlist-wasi.tar.gz frozenlist)

$(BUILD_DIR)/multidict-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd multidict && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a multidict/src/build/lib.*/multidict "$(@D)"
	(cd "$(@D)" && tar czf multidict-wasi.tar.gz multidict)

$(BUILD_DIR)/numpy-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd numpy && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a numpy/build/numpy "$(@D)"
	(cd "$(@D)" && tar czf numpy-wasi.tar.gz numpy)

$(BUILD_DIR)/numpy-static-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd numpy && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build-static.sh)
	cp -a numpy/build-static "$(@D)/numpy-static"
	(cd "$(@D)" && tar czf numpy-static-wasi.tar.gz numpy-static)

$(BUILD_DIR)/cpython-3.14-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	# Package libpython3.14.a, headers, and stdlib for downstream consumers
	mkdir -p "$(@D)/cpython-3.14-wasi"
	cp $(CPYTHON)/lib/libpython3.14.a "$(@D)/cpython-3.14-wasi/"
	cp -a $(CPYTHON)/include/python3.14 "$(@D)/cpython-3.14-wasi/include/"
	cp -a $(CPYTHON)/lib/python3.14 "$(@D)/cpython-3.14-wasi/lib/"
	(cd "$(@D)" && tar czf cpython-3.14-wasi.tar.gz cpython-3.14-wasi)
	rm -rf "$(@D)/cpython-3.14-wasi"

$(BUILD_DIR)/pandas-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd pandas && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a pandas/src/build/lib.*/pandas "$(@D)"
	(cd "$(@D)" && tar czf pandas-wasi.tar.gz pandas)

$(BUILD_DIR)/pydantic_core-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd pydantic-core && PYO3_CROSS_LIB_DIR=$(PYO3_CROSS_LIB_DIR) CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a pydantic-core/src/build/*/pydantic_core "$(@D)"
	(cd "$(@D)" && tar czf pydantic_core-wasi.tar.gz pydantic_core)

$(BUILD_DIR)/regex-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd regex && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a regex/src/build/lib.*/regex "$(@D)"
	(cd "$(@D)" && tar czf regex-wasi.tar.gz regex)

$(BUILD_DIR)/tiktoken-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd tiktoken && CROSS_PREFIX=$(CPYTHON) SYSCONFIG=$(SYSCONFIG) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a tiktoken/src/build/tiktoken "$(@D)"
	(cd "$(@D)" && tar czf tiktoken-wasi.tar.gz tiktoken)

$(BUILD_DIR)/Pillow-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd pillow && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a pillow/[Pp]illow-*/build/*/PIL "$(@D)"
	(cd "$(@D)" && tar czf Pillow-wasi.tar.gz PIL)

$(BUILD_DIR)/sqlalchemy-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd sqlalchemy && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a sqlalchemy/src/build/lib.*/sqlalchemy "$(@D)"
	(cd "$(@D)" && tar czf sqlalchemy-wasi.tar.gz sqlalchemy)

$(BUILD_DIR)/tiktoken_ext-wasi.tar.gz: $(BUILD_DIR)/tiktoken-wasi.tar.gz
	cp -a tiktoken/src/build/lib.*/tiktoken_ext "$(@D)"
	(cd "$(@D)" && tar czf tiktoken_ext-wasi.tar.gz tiktoken_ext)

$(BUILD_DIR)/tiktoken-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd tiktoken && PYO3_CROSS_LIB_DIR=$(PYO3_CROSS_LIB_DIR) CROSS_PREFIX=$(CPYTHON) SYSCONFIG=$(SYSCONFIG) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a tiktoken/src/build/lib.*/tiktoken "$(@D)"
	cp -a tiktoken/src/build/lib.*/tiktoken_ext "$(@D)"
	(cd "$(@D)" && tar czf tiktoken-wasi.tar.gz tiktoken tiktoken_ext)

$(BUILD_DIR)/wrapt-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd wrapt && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a wrapt/src/build/lib.*/wrapt "$(@D)"
	(cd "$(@D)" && tar czf wrapt-wasi.tar.gz wrapt)

$(BUILD_DIR)/yaml-wasi.tar.gz: $(BUILD_DIR)/_yaml-wasi.tar.gz
	cp -a yaml/src/build/lib.*/yaml "$(@D)"
	(cd "$(@D)" && tar czf yaml-wasi.tar.gz yaml)

$(BUILD_DIR)/_yaml-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd yaml && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a yaml/src/build/lib.*/_yaml "$(@D)"
	(cd "$(@D)" && tar czf _yaml-wasi.tar.gz _yaml)

$(BUILD_DIR)/yarl-wasi.tar.gz: $(WASI_SDK) $(CPYTHON)
	@mkdir -p "$(@D)"
	(cd yarl && CROSS_PREFIX=$(CPYTHON) WASI_SDK_PATH=$(WASI_SDK) bash build.sh)
	cp -a yarl/src/build/*/yarl "$(@D)"
	(cd "$(@D)" && tar czf yarl-wasi.tar.gz yarl)

# Download and unpack wasi-sdk-33
$(WASI_SDK):
	@mkdir -p "$(@D)"
	(cd "$(@D)" && \
		curl -fL https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-$(WASI_SDK_VERSION)/wasi-sdk-$(WASI_SDK_VERSION).0-$(HOST_ARCH)-$(HOST_OS).tar.gz \
		     -o wasi-sdk.tar.gz && \
		tar xf wasi-sdk.tar.gz && \
		mv wasi-sdk-$(WASI_SDK_VERSION).0-$(HOST_ARCH)-$(HOST_OS) wasi-sdk && \
		rm wasi-sdk.tar.gz)

# Download and unpack CPython 3.14 source tarball (no submodule needed)
$(CPYTHON_SRC):
	@mkdir -p "$(BUILD_DIR)"
	(cd "$(BUILD_DIR)" && \
		curl -fL $(CPYTHON_URL) -o $(CPYTHON_TARBALL) && \
		tar xf $(CPYTHON_TARBALL) && \
		mv Python-$(CPYTHON_VERSION) cpython-src && \
		rm $(CPYTHON_TARBALL))

# Build a native host Python (required as --with-build-python for cross-compile)
$(CPYTHON_HOST)/bin/python3: $(CPYTHON_SRC)
	@mkdir -p $(CPYTHON_HOST)
	(cd $(CPYTHON_HOST) && \
		$(CPYTHON_SRC)/configure \
			--prefix=$(CPYTHON_HOST) \
			--without-ensurepip && \
		make -j$$(nproc) && \
		make install)

# Cross-compile CPython for wasm32-wasip1 using official Tools/wasm/wasi-env
# Note: CPython 3.14 upstream marks --enable-wasm-dynamic-linking as "not yet
# implemented" for WASI, but the underlying linker support works fine.  We patch
# the configure guard away so we can still build a PIC-compiled libpython3.14.so
# that extension modules can dlopen-link against.
# Use order-only prerequisites (after |) so that if build/cpython-wasi/install
# already exists (CI cache hit), make won't rebuild it just because the source
# dirs were freshly downloaded and have newer timestamps.
$(CPYTHON): | $(WASI_SDK) $(CPYTHON_SRC) $(CPYTHON_HOST)/bin/python3
	@mkdir -p $(BUILD_DIR)/cpython-wasi
	# Patch out the configure guard that blocks --enable-wasm-dynamic-linking on WASI
	sed -i 's/as_fn_error \$$? "WASI dynamic linking is not implemented yet\." "\$$LINENO" 5/: ;; #  patched: WASI dynamic linking allowed/g' \
		$(CPYTHON_SRC)/configure
	(cd $(BUILD_DIR)/cpython-wasi && \
		WASI_SDK_PATH=$(WASI_SDK) \
		CONFIG_SITE=$(CPYTHON_SRC)/Tools/wasm/wasi/config.site-wasm32-wasi \
		CFLAGS=-fPIC \
		$(CPYTHON_SRC)/Tools/wasm/wasi-env \
		$(CPYTHON_SRC)/configure \
		-C \
		--host=wasm32-wasip1 \
		--build=$$($(CPYTHON_SRC)/config.guess) \
		--with-build-python=$(CPYTHON_HOST)/bin/python3 \
		--prefix=$$(pwd)/install \
		--enable-wasm-dynamic-linking \
		--disable-ipv6 \
		--disable-test-modules && \
		make -j$$(nproc) build_all install && \
		$(WASI_SDK)/bin/clang \
		--target=wasm32-wasip1 \
		-shared \
		-o $(CPYTHON)/lib/libpython3.14.so \
		-Wl,--whole-archive $(CPYTHON)/lib/libpython3.14.a -Wl,--no-whole-archive \
		$(BUILD_DIR)/cpython-wasi/Modules/_hacl/libHacl_HMAC.a \
		$(BUILD_DIR)/cpython-wasi/Modules/_hacl/libHacl_Hash_BLAKE2.a \
		$(BUILD_DIR)/cpython-wasi/Modules/_hacl/libHacl_Hash_MD5.a \
		$(BUILD_DIR)/cpython-wasi/Modules/_hacl/libHacl_Hash_SHA1.a \
		$(BUILD_DIR)/cpython-wasi/Modules/_hacl/libHacl_Hash_SHA2.a \
		$(BUILD_DIR)/cpython-wasi/Modules/_hacl/libHacl_Hash_SHA3.a \
		$(BUILD_DIR)/cpython-wasi/Modules/_decimal/libmpdec/libmpdec.a \
		$(BUILD_DIR)/cpython-wasi/Modules/expat/libexpat.a \
		-lwasi-emulated-signal \
		-lwasi-emulated-getpid \
		-lwasi-emulated-process-clocks \
		-ldl)
	# Write maturin-format build-details.json (required by maturin >= 1.7).
	# maturin expects: {"language":{"version":"3.14"}, "implementation":{"name":"CPython"},
	#                   "abi":{"flags":[], "extension_suffix":"..."}}
	# CPython 3.14 WASI generates a flat sysconfig JSON — replace it entirely.
	python3 -c "\
import json; \
p = '$(SYSCONFIG)/build-details.json'; \
d = {'language': {'version': '3.14'}, 'implementation': {'name': 'CPython'}, 'abi': {'flags': [], 'extension_suffix': '.cpython-314-wasm32-wasi.so'}}; \
json.dump(d, open(p, 'w'), indent=2); \
print('Wrote maturin-format build-details.json:', p)"

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	find . -name 'venv' -maxdepth 2 | xargs -I {} rm -rf {}
	find . -name 'build' -maxdepth 3 | xargs -I {} rm -rf {}
	find . -name 'dist' -maxdepth 3 | xargs -I {} rm -rf {}
