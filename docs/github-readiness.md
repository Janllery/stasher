# GitHub preparation notes

The first public release is Stasher 1.0, build 1. These notes cover publishing the source, not a notarized installer or an independent security certification.

## Privacy checks

The source package uses the explicit file list in `Tools/source-release-files.txt`. It contains source, build and test tools, documentation, licenses, the wordlist, the Public Suffix List, the app icon, and one fictional-data screenshot. It does not include local app bundles, signing configuration, private keys, credential CSV exports, Keychain files, encrypted vaults, backups, build caches, or Git metadata.

The release review checked the publishable files for private-key markers, common service tokens, embedded URL credentials, and local home-directory paths. It reviewed the nonempty password literals in the tests. Those values and the test card number are synthetic. The screenshot shows fictional accounts at reserved example domains and has no text or EXIF metadata. No real Keychain password values were read for this review.

The local repository had no commits or remotes at review time. There was no earlier committed history to publish accidentally. `.gitignore` excludes local runtime files. The package manifest provides a separate boundary because ignore rules alone do not exclude a sensitive file that was already committed.

Pattern scanning cannot recognize every arbitrary password or private detail. Review changed text and images before publishing a later release. Run `python3 Tools/prepare-source-release.py` to regenerate the ZIP and its checksums.

## Verification performed

The reviewed source ZIP was extracted into a clean temporary directory with no Git metadata, local signing identity, or existing app bundle. Its per-file checksums passed. The extracted source passed `Tools/verify-keychain.sh`, `build.sh` with ad hoc signing, and strict bundle-signature verification. The temporary test app was removed, and the current local app's executable stayed unchanged.

The authentication-count tests inject a test authenticator and use actual Keychain APIs for synthetic records. They verify the app's session behavior, not every macOS authentication or item-permission dialog. No separate fresh macOS user account was tested.

The package guard also rejected synthetic examples of a service token, a local environment file, and a local home-directory path. The final archive was checked against the reviewed file list and source checksums.

## User authentication

Stasher automatically asks macOS to verify the user when the app starts. Touch ID or the Mac login password opens an app session. Panel reopening and ordinary record access reuse that session. Sleep and screen lock clear the interface and owned clipboard without ending the app session. Quitting, restarting the Mac, or selecting **Lock App** requires a new app verification.

Keychain item permissions are separate. Existing records or a replacement signature can still trigger macOS access prompts. A new user does not receive the publisher's records or the publisher's Keychain grants. This release does not offer permanent password-free access after one installation prompt.

## Distribution scope

The source has an MIT license, third-party notices, English build and usage instructions, security reporting instructions, and synthetic Keychain tests. The documented installation path is building locally with Apple's Command Line Tools on macOS 14 or later.

The free build uses ad hoc signing on a fresh checkout. The current local app uses a local signing certificate. It is not a Developer ID notarized distribution build. Downloaded apps can require a separate Gatekeeper approval. See [Apple's app-opening guide](https://support.apple.com/en-us/102445) and [Keychain authorization guide](https://support.apple.com/en-lb/guide/keychain-access/kyca1243/mac).

Before publishing a ready-to-run binary, account for its target architecture, download and Gatekeeper behavior, signing identity, and Keychain upgrade prompts. Source publication does not establish a frictionless binary installation flow.

## Publish the reviewed source

1. Run `python3 Tools/prepare-source-release.py`.
2. Extract `dist/Stasher-1.0-source.zip` into a clean folder.
3. Initialize Git in that clean folder and push it to the chosen GitHub repository. Preserve executable permissions for the build and test scripts.
4. Enable private vulnerability reporting for the repository.

The ZIP includes `SOURCE-MANIFEST.sha256`. From its extracted root, run `shasum -a 256 -c SOURCE-MANIFEST.sha256` to verify the packaged source files.
