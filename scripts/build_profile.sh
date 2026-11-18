#!/bin/bash
# Select the exact executable profile supported by scripts/build.sh.
# Keep the Steam profile first/default behavior unchanged; unknown hashes fail closed.
profile_for_sha256() {
    case "$1" in
        3d8b4393649f80bdae85c19ae2c985c45ec9ac54f74ab04a18816e30ead63c21) printf '%s\n' steam ;;
        a32df8ffa042090f14fe0a200f1c5d7dddf9c947fac223916c252f826f1ecf11) printf '%s\n' gog ;;
        *) return 1 ;;
    esac
}
