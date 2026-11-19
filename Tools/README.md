# Check Keychain access after an upgrade

Stasher 1.0 uses Apple Keychain for daily storage. This optional local tool checks password, address, card, and category-setting items whose existing access rules already trust the updated app. It keeps those rules and appends the verified current build's code hash. It does not read password values or make unrelated Keychain items accessible.

Build the app with your original signing certificate. These commands assume the project root contains `.local-signing-identity` with the certificate fingerprint. From the project root, build the repair tool and run the read-only check.

```sh
./build.sh
xcrun clang -fobjc-arc -framework Foundation -framework Security \
    Tools/RepairKeychain.m -o dist/.password-reminder-keychain-repair
dist/.password-reminder-keychain-repair "dist/Stasher.app" \
    "$(< .local-signing-identity)" --check
```

If the check finds items that need repair, run the final command again without `--check`. Enter your local login Keychain password at the Terminal prompt. You can also run `Tools/repair-keychain-access.command` after building the repair tool.

The tool uses private macOS Security APIs. If those APIs are unavailable on your macOS version, use the system's Keychain authorization prompts.

## Verify native Keychain behavior

Run `Tools/verify-keychain.sh` in a macOS login session. It uses an isolated temporary Keychain and synthetic data to verify session authentication, CRUD, stale revisions, categories, and import from the old encrypted format. See [the storage and release notes](../docs/releases.md).

## Prepare the source archive

Run `python3 Tools/prepare-source-release.py` from the project root. The script checks `source-release-files.txt` and creates a source ZIP under `dist/`. It rejects duplicate paths, symbolic links, unapproved file types, and common credential-token patterns. It also checks that the screenshot has no text or EXIF metadata. It does not read the login Keychain or local vault.

Review the manifest and any changed source or image before every release. Pattern checks cannot identify every possible password or private detail. The ZIP contains a SHA-256 manifest for checking the extracted files.

## Rebuild the Finder icon

The Finder icon uses the same shield and lock as the menu bar. Run these commands from the project root after changing the mark.

```sh
mkdir -p .build
xcrun swiftc Sources/StasherMark.swift Tools/RenderAppIcon.swift -o .build/render-app-icon
.build/render-app-icon .build/Stasher.iconset
iconutil -c icns .build/Stasher.iconset -o Resources/AppIcon.icns
```
