# Keychain storage and release notes

## Version 1.0

Stasher 1.0 is the first public release. Passwords, addresses, and cards are stored in Apple Keychain. The default build explicitly uses the local login Keychain and keeps the existing service names and record UUIDs. Existing records from the original Keychain versions need no data conversion.

Stasher requests macOS identity verification once per app session. Reopening the panel and returning after screen lock reuse that session. Sleep and screen lock clear the interface and owned clipboard content. **Lock App** and quitting end the session. Stasher no longer creates a master password or applies a five-minute idle lock.

This session policy does not override item-level macOS Keychain permissions. A new signature can still cause authorization prompts for older items. This release does not promise authorization continuity across future builds. Keep the original signing identity and bundle identifier when rebuilding. The local [access repair tool](../Tools/README.md) can append the verified current build's hash to eligible old items without replacing their existing access rules.

## Import a pre-release encrypted vault

Select **Import Encrypted Vault…** and enter its master password. The file is normally at:

`~/Library/Containers/local.passwordreminder.app/Data/Library/Application Support/local.passwordreminder.app/vault.stasher`

For an unsandboxed installation, it is under `~/Library/Application Support/local.passwordreminder.app/`. The importer uses the current app's Application Support location. Keep the bundle identifier `local.passwordreminder.app` to retain access to that location.

The compatibility reader supports authenticated AES-GCM vault formats 1 and 2, including their original Unicode password handling. It is read-only. Normal use does not open or update the file.

Before writing to Keychain, the importer validates the source records. Each saved record is read back for verification. Identical records are skipped, and conflicts keep the existing Keychain record. An interrupted import can be retried. An import is not one atomic transaction across all Keychain items: a failure can leave a verified partial import, reported in the error. Source files and backups remain unchanged. Newly imported records receive Keychain modification dates.

Check the imported records before removing any old file. Keep encrypted backups and their master password if you still need them. Password CSV exports contain plaintext and require separate care.

## Verification

Run these checks in a macOS login session:

```sh
Tools/verify-keychain.sh
```

The tests create and delete a temporary Keychain containing synthetic records. They cover one session authentication, lock and unlock, credential and wallet CRUD, stale revisions, metadata-only listing, encrypted category preferences, CSV snapshots, archive import, retries, conflicts, wrong passwords, Unicode compatibility, and cancellation. They do not read the user's real passwords.

## Build and distribution

Use `./build.sh` for a local build. A fresh checkout uses ad hoc signing. A local `.local-signing-identity` file selects the installed signing certificate by fingerprint, and `PASSWORD_REMINDER_SIGNING_IDENTITY` overrides it. Signing private keys and local configuration must not be committed.

Developers with a Developer ID Application certificate can run `./build.sh --release` after setting `PASSWORD_REMINDER_SIGNING_IDENTITY`. The output is `dist/release/Stasher.app`. This command signs and verifies the bundle. Notarization and stapling are separate distribution steps.

The optional provisioning-profile build uses Data Protection Keychain when matching entitlements and `PASSWORD_REMINDER_PROVISIONING_PROFILE` are supplied. It is a different Keychain storage domain from the default local login Keychain. Do not change that setting for an existing installation without a separate migration plan.
