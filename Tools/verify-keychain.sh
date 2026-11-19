#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage="$(mktemp -d /private/tmp/stasher-keychain-tests.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
mkdir -p .build/swift-cache
xcrun swiftc -O -suppress-warnings -module-cache-path .build/swift-cache \
    Sources/StoredRecord.swift Sources/CancellationToken.swift Sources/KeychainDatabase.swift \
    Sources/EncryptedVaultArchive.swift Sources/VaultMigration.swift Sources/Credentials.swift \
    Sources/Wallet.swift Tests/KeychainTests.swift -o "$stage/keychain-tests"
"$stage/keychain-tests" "$stage/data"
