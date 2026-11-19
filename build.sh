#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

release_build=false
if [[ "${1:-}" == --release ]]; then
    release_build=true
    shift
fi
if (( $# != 0 )); then
    printf '%s\n' 'Usage: ./build.sh [--release]' >&2
    exit 2
fi

output_dir="$PWD/dist"
timestamp_options=(--timestamp=none)
if $release_build; then
    if [[ -z "${PASSWORD_REMINDER_SIGNING_IDENTITY:-}" || "${PASSWORD_REMINDER_SIGNING_IDENTITY:-}" == - ]]; then
        printf '%s\n' 'Notarized release builds require a Developer ID Application identity. Use ./build.sh for the local Keychain build.' >&2
        exit 1
    fi
    output_dir="$output_dir/release"
    timestamp_options=(--timestamp)
fi

mkdir -p .build/swift-cache "$output_dir"
stage="$(mktemp -d "$PWD/.build/bundle.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/Stasher.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cp Resources/public_suffix_list.dat "$bundle/Contents/Resources/public_suffix_list.dat"
cp Resources/eff_large_wordlist.txt Resources/eff_wordlist_attribution.txt "$bundle/Contents/Resources/"
cp LICENSE "$bundle/Contents/Resources/LICENSE"

signing_identity="${PASSWORD_REMINDER_SIGNING_IDENTITY:-}"
signing_options=(--force --options runtime "${timestamp_options[@]}")
if [[ -z "$signing_identity" && -f .local-signing-identity ]]; then
    read -r signing_identity < .local-signing-identity
    if [[ ! "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        printf '%s\n' 'The local signing identity file must contain a certificate fingerprint.' >&2
        exit 1
    fi
    signing_options+=(--keychain "$HOME/Library/Keychains/login.keychain-db")
fi
signing_identity="${signing_identity:--}"
signing_options+=(--sign "$signing_identity")
entitlements="${PASSWORD_REMINDER_ENTITLEMENTS:-Resources/Local.entitlements}"

if [[ -n "${PASSWORD_REMINDER_PROVISIONING_PROFILE:-}" ]]; then
    if [[ "$signing_identity" == - || -z "${PASSWORD_REMINDER_ENTITLEMENTS:-}" ]]; then
        printf '%s\n' 'A provisioning profile requires a signing identity and matching entitlements.' >&2
        exit 1
    fi
    cp "$PASSWORD_REMINDER_PROVISIONING_PROFILE" "$bundle/Contents/embedded.provisionprofile"
    /usr/libexec/PlistBuddy -c 'Add :UseDataProtectionKeychain bool true' "$bundle/Contents/Info.plist"
fi

architecture="$(uname -m)"
xcrun swiftc -O -target "$architecture-apple-macosx14.0" \
    -module-cache-path "$PWD/.build/swift-cache" \
    Sources/*.swift -o "$bundle/Contents/MacOS/Stasher"

/usr/bin/codesign "${signing_options[@]}" --entitlements "$entitlements" "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
if $release_build; then
    release_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    /usr/bin/codesign --verify --strict --test-requirement "=$release_requirement" "$bundle"
fi

output="$output_dir/Stasher.app"
if [[ -d "$output" ]]; then
    mv "$output" "$stage/previous.app"
fi
if ! mv "$bundle" "$output"; then
    if [[ -d "$stage/previous.app" ]]; then
        mv "$stage/previous.app" "$output"
    fi
    exit 1
fi
printf '%s\n' "$output"
