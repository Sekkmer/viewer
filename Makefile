J ?= $(shell nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 8)
ADDRSIZE ?= 64
CONFIG ?= ReleaseOS
CHANNEL ?= Sekkmer

FMOD_VERSION ?= 20225
FMOD_SDK ?= $(HOME)/Downloads/fmodstudioapi$(FMOD_VERSION)linux
USE_FMODSTUDIO ?= OFF
FMOD_LIBRARY ?= /usr/lib/libfmodstudio.so
FMOD_INCLUDE_DIR ?= /usr/include/fmodstudio

# Tooling autodetect (can be overridden by environment)
HAVE_NINJA := $(shell command -v ninja >/dev/null 2>&1 && echo 1 || echo 0)
HAVE_CCACHE := $(shell command -v ccache >/dev/null 2>&1 && echo 1 || echo 0)
HAVE_CLANG := $(shell command -v clang >/dev/null 2>&1 && echo 1 || echo 0)
HAVE_MOLD  := $(shell command -v mold  >/dev/null 2>&1 && echo 1 || echo 0)

# Prefer Ninja when present. Use a less collision-prone name than GENERATOR.
CMAKE_GEN ?= $(if $(filter 1,$(HAVE_NINJA)),Ninja,Unix Makefiles)

# Prefer clang/clang++ when present
CC  ?= $(if $(filter 1,$(HAVE_CLANG)),clang,gcc)
CXX ?= $(if $(filter 1,$(HAVE_CLANG)),clang++,g++)

SRCROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VENV    := $(SRCROOT)/.venv
BUILD   ?= $(SRCROOT)/build-linux-x86_64
FSVARS  ?= $(SRCROOT)/../fs-build-variables/variables
PYTHON  ?= python3
AUTOBUILD ?= autobuild

# Runtime options
RUN_ARGS    ?=
# Seconds; used by the smoke target
RUN_TIMEOUT ?= 20
# Where the packaged app (wrapper + libs) lives
RUN_DIR     ?= $(BUILD)/newview/packaged

ifneq (,$(wildcard $(FSVARS)))
export AUTOBUILD_VARIABLES_FILE := $(FSVARS)
endif

export CFLAGS   ?= -O3 -pipe
export CXXFLAGS ?= -O3 -pipe
export LDFLAGS  ?= $(if $(filter 1,$(HAVE_MOLD)),-fuse-ld=mold,)

# Also pass mold explicitly via CMake cache for consistency
MOLD_CMAKE_FLAGS := $(if $(filter 1,$(HAVE_MOLD)),-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=mold -DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=mold -DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=mold,)

LL_TESTS ?= OFF
PACKAGE ?= OFF
USE_AUTOBUILD_3P ?= OFF

# Extra user-provided cmake flags
CMAKE_USER_FLAGS ?=

# Assemble common cmake options; preserve ordering to keep cache diffs tidy.
CMAKE_COMMON_FLAGS := \
  -DCMAKE_C_COMPILER=$(CC) \
  -DCMAKE_CXX_COMPILER=$(CXX) \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLL_TESTS:BOOL=$(LL_TESTS) \
  -DPACKAGE:BOOL=$(PACKAGE) \
  -DVIEWER_CHANNEL:STRING=$(CHANNEL) \
  -DUSE_AUTOBUILD_3P:BOOL=$(USE_AUTOBUILD_3P) \
  -DLL_ENABLE_RELEASE_FOR_DOWNLOAD:BOOL=OFF \
  $(MOLD_CMAKE_FLAGS)

TRACY_FLAGS := -DUSE_TRACY:BOOL=ON -DUSE_TRACY_GPU:BOOL=ON -DUSE_TRACY_ON_DEMAND:BOOL=ON
TRACY_GUI ?= tracy-profiler

ifeq ($(HAVE_CCACHE),1)
CMAKE_COMMON_FLAGS += -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
endif

ifeq ($(USE_FMODSTUDIO),ON)
CMAKE_COMMON_FLAGS += -DUSE_FMODSTUDIO:BOOL=ON \
  -DFMODSTUDIO_LIBRARY=$(FMOD_LIBRARY) \
  -DFMODSTUDIO_INCLUDE_DIR=$(FMOD_INCLUDE_DIR)
else
CMAKE_COMMON_FLAGS += -DUSE_FMODSTUDIO:BOOL=OFF
endif

CMAKE_COMMON_FLAGS += $(CMAKE_USER_FLAGS)

.PHONY: all venv configure configure-tracy build build-tracy package run run-tracy tracy-profiler clean distclean clobber reconfigure shader

all: build

$(VENV):
	@echo ">>> Creating virtual environment"
	$(PYTHON) -m venv $(VENV)
	. $(VENV)/bin/activate && \
		pip3 install --upgrade pip && \
		pip3 install --upgrade autobuild llbase
venv: $(VENV)

fmod:
	@test -d $(FMOD_SDK) || { echo "FMOD SDK not found at $(FMOD_SDK)"; exit 1; }
	sudo mkdir -p /usr/include/fmodstudio
	sudo cp -r $(FMOD_SDK)/api/core/inc/* /usr/include/fmodstudio
	sudo cp -r $(FMOD_SDK)/api/core/lib/`uname -m`/* /usr/lib

$(BUILD)/CMakeCache.txt: venv
	@echo ">>> autobuild configure ($(CONFIG))"
	. $(VENV)/bin/activate && \
		$(AUTOBUILD) configure -A $(ADDRSIZE) -c $(CONFIG) \
		-- \
		-G "$(CMAKE_GEN)" \
		$(CMAKE_COMMON_FLAGS)
configure: $(BUILD)/CMakeCache.txt

build: configure
	@echo ">>> cmake --build $(BUILD) --parallel $(J)"
	cmake --build $(BUILD) --parallel $(J)

package: configure
	@echo ">>> autobuild build ($(CONFIG))"
	. $(VENV)/bin/activate && $(AUTOBUILD) build -A $(ADDRSIZE) -c $(CONFIG)

configure-tracy:
	$(MAKE) configure CMAKE_USER_FLAGS="$(CMAKE_USER_FLAGS) $(TRACY_FLAGS)"

build-tracy:
	$(MAKE) build CMAKE_USER_FLAGS="$(CMAKE_USER_FLAGS) $(TRACY_FLAGS)"

shader: configure
	@echo ">>> syncing updated shaders"
	@rsync -a --delete $(SRCROOT)/indra/newview/app_settings/shaders/ $(BUILD)/newview/packaged/app_settings/shaders/

run: build
	@echo ">>> launching viewer (packaged wrapper)"
	@cd $(RUN_DIR) && ./secondlife $(RUN_ARGS)

run-tracy: build-tracy
	@echo ">>> launching viewer with Tracy instrumentation"
	@cd $(RUN_DIR) && ./secondlife $(RUN_ARGS)

# Quick smoke test: run viewer for RUN_TIMEOUT seconds, then exit.
# Returns success when the viewer times out (124) or exits cleanly (0).
.PHONY: smoke
smoke: build
	@echo ">>> smoke test: timeout $(RUN_TIMEOUT)s"
	@cd $(RUN_DIR) && \
		timeout --foreground $(RUN_TIMEOUT)s ./secondlife $(RUN_ARGS); \
		code=$$?; \
		if [ $$code -eq 124 ] || [ $$code -eq 0 ]; then \
		  echo ">>> smoke: OK (exit $$code)"; \
		  exit 0; \
		else \
		  echo ">>> smoke: FAIL (exit $$code)"; \
		  exit $$code; \
		fi

# Start under gdb using the wrapper's LL_WRAPPER hook
.PHONY: gdb
gdb: build
	@echo ">>> launching viewer under gdb"
	@cd $(RUN_DIR) && \
		LL_WRAPPER="gdb -q --args" ./secondlife $(RUN_ARGS)

clean:
	@if [ -d $(BUILD) ]; then cmake --build $(BUILD) --target clean; fi

tracy-profiler:
	@echo ">>> launching Tracy GUI ($(TRACY_GUI))"
	@if command -v $(TRACY_GUI) >/dev/null 2>&1; then \
		$(TRACY_GUI); \
	elif [ -x "$(TRACY_GUI)" ]; then \
		"$(TRACY_GUI)"; \
	else \
		echo "Tracy profiler GUI not found. Set TRACY_GUI to the executable path."; \
		exit 1; \
	fi

distclean:
	@echo ">>> removing CMake cache and generator files in $(BUILD)"
	@if [ -d $(BUILD) ]; then \
		rm -f $(BUILD)/CMakeCache.txt; \
		rm -rf $(BUILD)/CMakeFiles; \
		rm -f $(BUILD)/Makefile $(BUILD)/cmake_install.cmake; \
		rm -f $(BUILD)/build.ninja $(BUILD)/rules.ninja; \
	fi

clobber: distclean
	@echo ">>> removing build directory $(BUILD)"
	@if [ -d $(BUILD) ]; then rm -rf $(BUILD); fi

reconfigure: distclean build
