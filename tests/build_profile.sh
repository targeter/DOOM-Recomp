#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/build_profile.sh"
cd "$ROOT"

steam_sha=3d8b4393649f80bdae85c19ae2c985c45ec9ac54f74ab04a18816e30ead63c21
gog_sha=a32df8ffa042090f14fe0a200f1c5d7dddf9c947fac223916c252f826f1ecf11
[[ "$(profile_for_sha256 "$steam_sha")" == steam ]]
[[ "$(profile_for_sha256 "$gog_sha")" == gog ]]
grep -Fq "\"$steam_sha\"" "$ROOT/setup/macos/Installer.swift"
grep -Fq "\"$gog_sha\"" "$ROOT/setup/macos/Installer.swift"
if profile_for_sha256 "$(printf '0%.0s' {1..64})" >/dev/null; then
    echo "unknown executable hash was accepted" >&2
    exit 1
fi

gog_gen="$(make -s -n GAME_PROFILE=gog gen)"
[[ "$gog_gen" == *"orig.exe gen-gog"* ]]
[[ "$gog_gen" != *"--native"* && "$gog_gen" == *"--patches tools/patches-gog.txt"* ]]
steam_gen="$(make -s -n GAME_PROFILE=steam gen)"
[[ "$steam_gen" == *"orig.exe gen --native tools/native.txt --patches tools/patches.txt"* ]]

gog_vars="$(make -pn GAME_PROFILE=gog | grep -E '^(BUILD|GEN_DIR|NATIVE|PATCHES) =')"
[[ "$gog_vars" == *"BUILD = build-gog"* && "$gog_vars" == *"GEN_DIR = gen-gog"* ]]
[[ "$gog_vars" == *"NATIVE = "* && "$gog_vars" == *"PATCHES = tools/patches-gog.txt"* ]]
steam_vars="$(make -pn GAME_PROFILE=steam | grep -E '^(BUILD|GEN_DIR|NATIVE|PATCHES) =')"
[[ "$steam_vars" == *"BUILD = build"* && "$steam_vars" == *"GEN_DIR = gen"* ]]
[[ "$steam_vars" == *"NATIVE = tools/native.txt"* && "$steam_vars" == *"PATCHES = tools/patches.txt"* ]]
if make -s -n GAME_PROFILE=unknown gen >/dev/null 2>&1; then
    echo "unknown build profile was accepted" >&2
    exit 1
fi

git check-ignore -q gen-gog
git check-ignore -q build-gog
echo "profile hash selection passed"
