# DOOM (2016) on Recomp-Framework (framework/, a git submodule): static recompilation to native arm64 macOS.
#   make gen gen-dll gen-bink   translate DOOMx64vk.exe, superscriptx64.dll and bink2w64.dll
#   make -j8 boot               build the runtime + translated game
#   make app                    build/DOOM.app
#   make kosmickrisp            build the Vulkan driver from Mesa (with the framework's patches)
FW        = framework
PYTHON    = .venv/bin/python
BUILD     = build
GAME_EXE ?= orig.exe
APP_NAME  = DOOM
BUNDLE_ID = com.nightsightproductions.doom-recomp
APP_CATEGORY = public.app-category.action-games
GAME_SRC  = src/game.c src/native_idtech.c
NATIVE    = tools/native.txt
PATCHES   = tools/patches.txt
GAME_PROFILE ?= steam
ifeq ($(GAME_PROFILE),gog)
# GOG executable uses different function addresses: translate guest code directly, with no
# Steam-address native overrides, and apply only its profile-specific menu instruction patches.
NATIVE =
PATCHES = tools/patches-gog.txt
GEN_DIR = gen-gog
BUILD = build-gog
else ifneq ($(GAME_PROFILE),steam)
$(error Unsupported GAME_PROFILE '$(GAME_PROFILE)' (choose steam or gog))
endif
# the game's DLLs that contain code, translated as modules (rules below)
EXTRA_LIBS_FORCE = $(BUILD)/libsuperscriptx64.a $(BUILD)/libbink2w64.a

include $(FW)/recomp.mk
# The game synchronizes its threads through integer flags and locks, so float and vector accesses don't need
# x86 ordering (see the framework README, "Memory ordering")
GEN_CFLAGS += -DRT_RELAX_FP

# superscriptx64.dll (the script VM); orig_superscript.dll links to the game's copy, like orig.exe
SUPERSCRIPT_DLL ?= orig_superscript.dll
$(eval $(call MODULE_RULES,superscriptx64,$(SUPERSCRIPT_DLL),gen_superscript,,))
# RAD Bink 2 (bink2w64.dll): same preferred base as superscriptx64, so it is translated rebased to 0x182000000.
# It only synchronizes through kernel objects, so it needs no TSO ordering.
BINK_DLL ?= orig_bink.dll
$(eval $(call MODULE_RULES,bink2w64,$(BINK_DLL),gen_bink,--rebase 182000000 --no-abi-trim,-DRT_TSO=0))

gen-dll: gen-superscriptx64
gen-bink: gen-bink2w64
.PHONY: gen-dll gen-bink
