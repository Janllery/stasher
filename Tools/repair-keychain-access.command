#!/bin/bash
set -u

cd -- "$(dirname -- "$0")/.." || exit 1
tool="$PWD/dist/.password-reminder-keychain-repair"
app="${1:-$PWD/dist/Stasher.app}"
identity="$PWD/.local-signing-identity"

if [[ ! -x "$tool" || ! -f "$identity" || ! -d "$app" ]]; then
    printf '%s\n' 'Could not find the updated app, repair tool, or signing identity. See Tools/README.md.'
    exit 1
fi

printf '%s\n' 'Repair local Keychain access for Stasher.' \
    'This adds access for the updated app and keeps existing access rules.'
"$tool" "$app" "$(< "$identity")"
exit $?
