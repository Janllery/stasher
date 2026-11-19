import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

private struct TestFailure: Error {
    let message: String
}

private actor AuthenticationCounter {
    private(set) var count = 0

    func accepted() {
        count += 1
    }
}

private actor AuthenticationGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@main
struct KeychainTests {
    private static let master = "synthetic café master"
    private static let secret = "SYNTHETIC_ONLY_PASSWORD"

    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keychainURL = directory.appendingPathComponent("synthetic.keychain-db")
        let fixturePassword = "synthetic keychain password"
        var fixture: SecKeychain?
        let status = fixturePassword.withCString {
            SecKeychainCreate(keychainURL.path, UInt32(fixturePassword.utf8.count), $0, false, nil, &fixture)
        }
        guard status == errSecSuccess, let fixture else {
            throw TestFailure(message: "Could not create isolated Keychain (\(status))")
        }
        defer { SecKeychainDelete(fixture) }

        let counter = AuthenticationCounter()
        let database = KeychainDatabase(localKeychainURL: keychainURL, usesDataProtection: false) { _ in
            await counter.accepted()
        }
        try await rejects { _ = try await database.records(service: CredentialStore.service) }
        async let first: Void = database.unlock()
        async let second: Void = database.unlock()
        _ = try await (first, second)
        try await database.unlock()
        try check(await counter.count == 1, "Session requested identity verification more than once")

        let store = CredentialStore(database: database)
        var draft = CredentialDraft()
        draft.website = "https://example.com"
        draft.loginName = "synthetic-user"
        draft.name = "Synthetic site"
        let initial = try await store.add(draft.metadata(id: UUID(), url: draft.websiteURL!), password: secret)
        let listed = try await store.list()
        try check(listed.count == 1 && listed[0] == initial, "Metadata list did not return the saved OS revision")
        try check(try await store.password(for: initial) == secret, "Saved password could not be copied")
        let metadataOnly = try await database.records(service: CredentialStore.service)
        try check(metadataOnly[0].secret.isEmpty, "Metadata listing fetched plaintext passwords")

        var editedDraft = CredentialDraft(credential: initial)
        editedDraft.remarks = "Synthetic note"
        let edited = try await store.update(editedDraft.metadata(id: initial.id, url: initial.url),
                                            password: nil, expectedModifiedAt: initial.modifiedAt)
        try check(try await store.password(for: edited) == secret, "Metadata update changed the password")
        try await rejects { _ = try await store.password(for: initial) }
        try await rejects { try await store.delete(initial) }

        let wallet = WalletStore(database: database)
        var address = WalletDraft(kind: .address)
        address.label = "Synthetic address"
        address.fields = [.country: "US", .street: "Synthetic street"]
        let savedAddress = try await wallet.save(address.record(kind: .address), editing: false)
        try check(try await wallet.read(savedAddress.summary).fields == savedAddress.fields, "Address read failed")
        var card = WalletDraft(kind: .card)
        card.label = "Synthetic card"
        card.fields = [.cardholder: "Synthetic", .number: "4111111111111111", .expiration: "12/30", .securityCode: "123"]
        let savedCard = try await wallet.save(card.record(kind: .card), editing: false)
        let updatedCard = try await wallet.save(savedCard, editing: true, expectedModifiedAt: savedCard.summary.modifiedAt)
        try await rejects { try await wallet.delete(savedCard.summary) }
        try await wallet.delete(updatedCard.summary)
        try check(try await wallet.list(.card).isEmpty, "Card deletion failed")

        let slots = try await database.rememberCategories(["Synthetic category"], legacySlots: ["Synthetic category": 3])
        try check(slots["Synthetic category"] == 3, "Category color was lost")
        let exported = try await store.exportRows()
        try check(exported.count == 1 && exported[0].entry == edited && exported[0].password == secret,
                  "CSV snapshot mixed account metadata and password")
        try check(await counter.count == 1, "CRUD caused another app authentication")

        let archiveURL = directory.appendingPathComponent("synthetic-vault.stasher")
        let imported = StoredRecord(service: CredentialStore.service, id: UUID(), label: "Imported synthetic",
                                    generic: Data("https://example.org".utf8), description: "", comment: "Synthetic",
                                    modifiedAt: .distantPast, secret: Data(secret.utf8))
        try writeArchive([imported], to: archiveURL, version: 2)
        let source = try Data(contentsOf: archiveURL)
        let archive = EncryptedVaultArchive(url: archiveURL)
        let result = try await VaultMigration.importAll(password: master, archive: archive, database: database)
        try check(result.imported == 1 && result.conflicts == 0, "Encrypted archive did not import")
        let retry = try await VaultMigration.importAll(password: master, archive: archive, database: database)
        try check(retry.imported == 0 && retry.skipped == 1, "Repeated archive import created duplicates")
        try check(try Data(contentsOf: archiveURL) == source, "Archive import changed the original file")
        var conflict = imported
        conflict.secret = Data("different synthetic value".utf8)
        let conflicts = try await database.importRecords([conflict])
        try check(conflicts.conflicts == 1, "Conflicting source replaced a Keychain item")
        try check(try await database.record(service: imported.service, id: imported.id).secret == imported.secret,
                  "Conflict overwrote the existing password")
        try await rejects { _ = try await archive.read(password: "wrong password") }
        try writeArchive([imported], to: archiveURL, version: 1)
        _ = try await archive.read(password: "synthetic cafe\u{0301} master")

        let token = CancellationToken()
        token.cancel()
        do {
            _ = try await VaultMigration.importAll(password: master, cancellation: token, archive: archive, database: database)
            throw TestFailure(message: "Canceled archive import ran")
        } catch is CancellationError {}

        let expectedSlots = try await database.categorySlots()
        try check(expectedSlots["Imported empty category"] == 2, "Archive category was not imported")
        await database.lock()
        try await rejects { _ = try await store.list() }
        try await database.unlock()
        try check(await counter.count == 2, "Manual lock did not start a new authentication session")
        try check(try await database.categorySlots() == expectedSlots, "Keychain category settings did not persist")

        let gate = AuthenticationGate()
        let interrupted = KeychainDatabase(localKeychainURL: keychainURL, usesDataProtection: false) { _ in
            await gate.wait()
        }
        let attempt = Task { try await interrupted.unlock() }
        while !(await gate.started) { try await Task.sleep(for: .milliseconds(10)) }
        await interrupted.lock()
        await gate.release()
        try await rejects { try await attempt.value }
        try await rejects { try await interrupted.requireUnlocked() }
        print("Native Keychain CRUD, single-session authentication, revisions, categories, archive migration, conflicts and cancellation passed.")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message: message) }
    }

    private static func rejects(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch is TestFailure {
            throw TestFailure(message: "Unexpected assertion failed")
        } catch {
            return
        }
        throw TestFailure(message: "Expected operation to fail")
    }

    private static func writeArchive(_ records: [StoredRecord], to url: URL, version: Int) throws {
        let salt = Data(repeating: 7, count: 16)
        var key = [UInt8](repeating: 0, count: 32)
        let bytes = Array(master.utf8)
        let status = bytes.withUnsafeBytes { password in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    password.bindMemory(to: Int8.self).baseAddress, bytes.count,
                    salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &key, key.count)
            }
        }
        try check(status == kCCSuccess, "Could not generate synthetic encrypted fixture")
        let header = try JSONSerialization.data(withJSONObject: [
            "magic": "StasherVault", "version": version, "kdf": "PBKDF2-HMAC-SHA256",
            "iterations": 600_000, "salt": salt.base64EncodedString()
        ])
        struct Payload: Encodable {
            let records: [StoredRecord]
            let categorySlots: [String: Int]
        }
        let payload = try JSONEncoder().encode(Payload(records: records, categorySlots: ["Imported empty category": 2]))
        let box = try AES.GCM.seal(payload, using: SymmetricKey(data: key), authenticating: header)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "header": header.base64EncodedString(), "sealed": box.combined!.base64EncodedString()
        ])
        try envelope.write(to: url)
    }
}
