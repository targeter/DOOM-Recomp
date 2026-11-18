#!/bin/bash
#
# Builds DOOM.app from YOUR copy of DOOM (2016), the Windows version from Steam or GOG.
#
# Nothing from the game is stored in this repository: the game's executable and its two code
# DLLs are translated to C on this machine and compiled for Apple Silicon, and the resulting app
# reads the game data from your install at run time.
#
# Usage: scripts/build.sh [path/to/DOOM]   (the folder that contains DOOMx64vk.exe)
#
# Requirements: Apple's Command Line Tools (xcode-select --install) and an internet connection
# the first time (two Python packages, Capstone and LIEF, are downloaded into .venv).
#
# Progress lines start with "==> [n/6]" so the installer can follow along.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/build_profile.sh"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> [$1/6] $2"; }

# The game folder: the argument, else the usual Steam locations (Windows Steam under CrossOver or Whisky).
find_game() {
    local c
    for c in \
        "$HOME/Library/Application Support/CrossOver/Bottles/"*"/drive_c/Program Files (x86)/Steam/steamapps/common/DOOM" \
        "$HOME/Library/Application Support/CrossOver/Bottles/"*"/drive_c/Program Files/Steam/steamapps/common/DOOM" \
        "$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles/"*"/drive_c/Program Files (x86)/Steam/steamapps/common/DOOM" \
        "$HOME/Library/Application Support/Steam/steamapps/common/DOOM"; do
        [[ -f "$c/DOOMx64vk.exe" ]] && { echo "$c"; return; }
    done
}
GAME="${1:-$(find_game)}"
[[ -n "$GAME" ]] || die "DOOM was not found. Pass the folder that contains DOOMx64vk.exe: scripts/build.sh /path/to/DOOM"

SHA_SUPERSCRIPT="dda81d1ee6c4e6de702b91ab12676cb13b6561bad7fbafa0f512da494381f5fb"  # superscriptx64.dll
SHA_BINK="c50d3f534986cb6b3f0eb32ecc9abc036d2bb670f85280c3ec10c5fdfe4f6b97"         # bink2w64.dll

step 1 "Checking requirements"
for t in clang make python3 codesign ar; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' was not found. Install Apple's Command Line Tools: xcode-select --install"
done
[[ "$(uname -m)" == "arm64" ]] || die "this build targets Apple Silicon Macs"

step 2 "Verifying your copy of the game"
sha256() {
    [[ -f "$GAME/$1" ]] || die "$1 was not found in: $GAME"
    shasum -a 256 "$GAME/$1" | awk '{print $1}'
}
EXE_SHA="$(sha256 DOOMx64vk.exe)"
PROFILE="$(profile_for_sha256 "$EXE_SHA")" ||
    die "DOOMx64vk.exe is not a supported Steam or GOG release (SHA-256 $EXE_SHA)."
check_dll() {
    local sha; sha="$(sha256 "$1")"
    [[ "$sha" == "$2" ]] || die "$1 is not the supported game DLL (SHA-256 $sha)."
}
check_dll superscriptx64.dll "$SHA_SUPERSCRIPT"
check_dll bink2w64.dll "$SHA_BINK"

# The GOG executable has different addresses. Translate its own code without Steam-address
# native replacements, and isolate generated files from the Steam output.
PROFILE_MAKE_ARGS=(-f Makefile "GAME_PROFILE=$PROFILE")
BUILD_DIR=build
[[ "$PROFILE" == gog ]] && BUILD_DIR=build-gog

step 3 "Preparing the translator"
if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
    python3 -m venv "$ROOT/.venv"
fi
"$ROOT/.venv/bin/python" -m pip install --quiet --disable-pip-version-check "capstone==5.0.6" "lief==0.16.6"

cd "$ROOT"
ln -sf "$GAME/DOOMx64vk.exe" orig.exe
ln -sf "$GAME/superscriptx64.dll" orig_superscript.dll
ln -sf "$GAME/bink2w64.dll" orig_bink.dll

step 4 "Translating the game's code to C (about 145,000 functions)"
make -s "${PROFILE_MAKE_ARGS[@]}" gen
make -s "${PROFILE_MAKE_ARGS[@]}" gen-dll
make -s "${PROFILE_MAKE_ARGS[@]}" gen-bink

step 5 "Compiling (this takes several minutes)"
make -s "${PROFILE_MAKE_ARGS[@]}" -j"$(/usr/sbin/sysctl -n hw.ncpu)" boot

step 6 "Packaging the app"
# The KosmicKrisp Vulkan driver: prebuilt in the installer (prebuilt/kosmickrisp), or built from Mesa
# source with `make kosmickrisp` (needs Homebrew's llvm, libclc and spirv-llvm-translator).
if [[ -d "$ROOT/prebuilt/kosmickrisp" ]]; then
    rm -rf "$BUILD_DIR/kosmickrisp" && cp -R "$ROOT/prebuilt/kosmickrisp" "$BUILD_DIR/kosmickrisp"
elif [[ ! -d "$BUILD_DIR/kosmickrisp" ]]; then
    echo "note: no prebuilt KosmicKrisp; the app will use a system install (/usr/local/share/vulkan/icd.d)"
fi
make -s "${PROFILE_MAKE_ARGS[@]}" app
# remember the game folder, so the app does not have to ask
mkdir -p "$HOME/Library/Application Support/doom-recomp"
printf '%s\n' "$GAME" > "$HOME/Library/Application Support/doom-recomp/game-dir.txt"

echo "Built: $ROOT/$BUILD_DIR/DOOM.app"
