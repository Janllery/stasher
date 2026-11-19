# Keychain storage review

This review records Stasher 1.0's implementation and local verification. It is not an independent professional security audit.

## Storage and authentication

Daily record storage uses Apple's Security framework. The default build explicitly targets the local login Keychain with the original service names for credentials, addresses, and cards. Passwords and full wallet fields are Keychain secret values. Site URLs, titles, usernames, notes, and record summaries use Keychain attributes and do not have the same secrecy boundary as a secret value. Category settings are stored as a Keychain secret value. Old plaintext category preference keys are removed after their successful transfer.

The app uses LocalAuthentication to verify the Mac's owner before creating an app session. Concurrent unlock requests share one pending authentication. Ordinary CRUD does not request another app verification while the session remains open. macOS independently enforces Keychain item access rules. App-session authentication cannot bypass those rules.

Sleep and screen lock hide the panel, cancel pending transfers, and clear displayed records, forms, and clipboard content still owned by Stasher. The session stays open for the requested once-per-launch workflow. **Lock App** invalidates the session and pending authentication. The app has no five-minute idle lock.

## Checks in the implementation

- Record lists request attributes only. Copying a secret reads that one item.
- Copy checks the selected record's metadata and Keychain revision before returning a password.
- Updates and deletion reject stale revisions. App writers serialize through a restricted lock file. Other Keychain clients do not participate in that app lock.
- CSV export pairs each account's metadata and secret in one item query and checks cancellation before publishing the plaintext file.
- HTTP pages cannot receive suggestions for stored HTTPS logins.
- Clipboard copies are local to the current host and clear after about 30 seconds if Stasher still owns them.
- The sandbox has no network client entitlement. Chrome suggestions use macOS Automation.

## Encrypted-file compatibility

The old AES-GCM vault code is a read-only importer. It retains support for formats 1 and 2 and the original PBKDF2 parameters and Unicode password behavior. File reads reject symlinks, non-regular files, foreign ownership, and oversized inputs. The authenticated header is checked during decryption.

Import validates the full source before starting writes, checks its Keychain session and cancellation, verifies each saved item, skips identical records, and keeps conflicting Keychain records. It leaves the original encrypted file and backup untouched. Keychain import is incremental and can be retried after a partial failure.

## Verification and limits

`Tools/verify-keychain.sh` exercises actual Security.framework calls against a temporary synthetic Keychain. It checks session authentication counts, credential and wallet CRUD, metadata-only listing, stale reads and deletion, category persistence, CSV snapshots, archive migration and retries, conflicts, wrong passwords, Unicode compatibility, and cancellation. GUI checks use isolated synthetic records and a private test clipboard.

The once-per-session behavior is a usability choice: the running app retains permission to read its records until manual locking or quitting. Keychain access rules still apply. A replacement build can require new item authorization.

The app can hold decrypted values in process memory during use. Swift and system components can retain copies. A compromised logged-in session, malicious software with sufficient privileges, other clipboard readers, and plaintext CSV exports remain outside the protection provided by storing secrets in Keychain.

Old encrypted files, original Keychain items, and manual exports are preserved rather than automatically deleted. They need a separate cleanup decision after verifying the desired records. Broader macOS compatibility testing and external professional auditing remain outstanding.
