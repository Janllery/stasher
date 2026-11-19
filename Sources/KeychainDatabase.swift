import Darwin
import Foundation
import LocalAuthentication
import Security

struct KeychainImportResult: Sendable {
    var imported = 0
    var skipped = 0
    var conflicts = 0
}

private struct KeychainImportFailure: LocalizedError {
    let progress: KeychainImportResult
    let cause: Error

    var errorDescription: String? {
        "Import stopped after verifying \(progress.imported) saved, \(progress.skipped) unchanged, and \(progress.conflicts) conflicting records. The source is preserved. \(cause.localizedDescription)"
    }
}

actor KeychainDatabase {
    static let shared = KeychainDatabase()
    static let defaultDataProtection = Bundle.main.object(forInfoDictionaryKey: "UseDataProtectionKeychain") as? Bool == true

    // LAContext supports invalidating an outstanding authentication from the lock path.
    // Keychain queries use this context only after that authentication completes.
    private struct Session: @unchecked Sendable {
        let id = UUID()
        let context: LAContext
    }

    private let localKeychainURL: URL?
    private let usesDataProtection: Bool
    private let authenticate: @Sendable (LAContext) async throws -> Void
    private let lockDirectory: URL
    private var localKeychain: SecKeychain?
    private var session: Session?
    private var pending: (session: Session, task: Task<Void, Error>)?

    init(localKeychainURL: URL? = nil, usesDataProtection: Bool = defaultDataProtection,
         authentication: @escaping @Sendable (LAContext) async throws -> Void = KeychainDatabase.authenticateOwner) {
        self.localKeychainURL = localKeychainURL
        self.usesDataProtection = usesDataProtection
        self.authenticate = authentication
        lockDirectory = localKeychainURL.map { $0.deletingLastPathComponent().appendingPathComponent(".stasher-locks") }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("local.passwordreminder.app", isDirectory: true)
    }

    private static let authenticateOwner: @Sendable (LAContext) async throws -> Void = { context in
        let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Stasher to use your saved logins, cards, and addresses.")
        guard accepted else { throw KeychainFailure.status(errSecAuthFailed) }
    }

    func unlock() async throws {
        if session != nil { return }
        if pending == nil {
            let candidate = Session(context: LAContext())
            let task = Task.detached { [authenticate] in try await authenticate(candidate.context) }
            pending = (candidate, task)
        }
        guard let attempt = pending else { throw KeychainFailure.locked }
        do {
            try await attempt.task.value
        } catch {
            if pending?.session.id == attempt.session.id {
                attempt.session.context.invalidate()
                pending = nil
            }
            throw error
        }
        if session?.id == attempt.session.id { return }
        guard pending?.session.id == attempt.session.id else { throw KeychainFailure.locked }
        session = attempt.session
        pending = nil
    }

    func lock() {
        pending?.session.context.invalidate()
        pending?.task.cancel()
        pending = nil
        session?.context.invalidate()
        session = nil
    }

    func requireUnlocked() throws {
        guard session != nil else { throw KeychainFailure.locked }
    }

    func sessionIdentifier() throws -> UUID {
        guard let session else { throw KeychainFailure.locked }
        return session.id
    }

    func records(service: String) throws -> [StoredRecord] {
        var query = try baseQuery(service: service)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let rows = result as? [[String: Any]] else { throw KeychainFailure.invalidRecord }
        return try rows.map { try decode($0, service: service, includesSecret: false) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func record(service: String, id: UUID) throws -> StoredRecord {
        try read(service: service, id: id, includesSecret: true)
    }

    func exportRecords(service: String, cancellation: CancellationToken? = nil) throws -> [StoredRecord] {
        try withWriteLock {
            try cancellation?.check()
            return try records(service: service).map { row in
                try cancellation?.check()
                return try record(service: service, id: row.id)
            }
        }
    }

    @discardableResult
    func add(_ row: StoredRecord) throws -> StoredRecord {
        try withWriteLock {
            try insert(row)
            var saved = try read(service: row.service, id: row.id, includesSecret: false)
            saved.secret = row.secret
            return saved
        }
    }

    @discardableResult
    func update(service: String, id: UUID, label: String, generic: Data, description: String?, comment: String?,
                secret: Data?, expectedModifiedAt: Date? = nil) throws -> StoredRecord {
        try withWriteLock {
            var row = try read(service: service, id: id, includesSecret: false)
            if let expectedModifiedAt, row.modifiedAt != expectedModifiedAt { throw KeychainFailure.changed }
            row.label = label
            row.generic = generic
            row.description = description
            row.comment = comment
            try replace(row, secret: secret, previous: row.modifiedAt)
            var saved = try read(service: service, id: id, includesSecret: false)
            saved.secret = secret ?? Data()
            return saved
        }
    }

    func delete(service: String, id: UUID, expectedModifiedAt: Date? = nil) throws {
        try withWriteLock {
            if let expectedModifiedAt {
                let current = try read(service: service, id: id, includesSecret: false)
                guard current.modifiedAt == expectedModifiedAt else { throw KeychainFailure.changed }
            }
            let query = try baseQuery(service: service, id: id)
            try check(SecItemDelete(query as CFDictionary))
        }
    }

    private static let settingsService = "local.passwordreminder.category-settings.v1"
    private static let settingsID = UUID(uuidString: "414D729D-09F2-48F9-A1C7-710B5F8B6ED0")!

    func categorySlots() throws -> [String: Int] {
        try storedCategorySlots() ?? [:]
    }

    private func storedCategorySlots() throws -> [String: Int]? {
        do {
            let row = try record(service: Self.settingsService, id: Self.settingsID)
            let slots = try JSONDecoder().decode([String: Int].self, from: row.secret)
            guard slots.values.allSatisfy({ (0..<Int.max).contains($0) }) else { throw KeychainFailure.invalidRecord }
            return slots
        } catch KeychainFailure.status(errSecItemNotFound) {
            return nil
        }
    }

    @discardableResult
    func rememberCategories(_ names: [String], legacySlots: [String: Int] = [:]) throws -> [String: Int] {
        try withWriteLock {
            let previous = try storedCategorySlots()
            var slots = previous ?? [:]
            for (name, slot) in legacySlots where !name.isEmpty && slots[name] == nil && (0..<1_000_000).contains(slot) {
                slots[name] = slot
            }
            let missing = Set(names.filter { !$0.isEmpty }).subtracting(slots.keys).sorted()
            var highest = slots.values.max() ?? -1
            for name in missing {
                guard highest < Int.max - 1 else { throw KeychainFailure.invalidRecord }
                highest += 1
                slots[name] = highest
            }
            guard slots != (previous ?? [:]) else { return slots }
            let row = StoredRecord(service: Self.settingsService, id: Self.settingsID, label: "Stasher category settings",
                                   generic: Data("v1".utf8), description: nil, comment: nil, modifiedAt: .now,
                                   secret: try JSONEncoder().encode(slots))
            if previous == nil {
                try insert(row)
            } else {
                let query = try baseQuery(service: row.service, id: row.id)
                try check(SecItemUpdate(query as CFDictionary, [kSecValueData: row.secret] as CFDictionary))
            }
            return slots
        }
    }

    func importRecords(_ source: [StoredRecord], replacingConflicts: Bool = false,
                       cancellation: CancellationToken? = nil, sessionID: UUID? = nil) throws -> KeychainImportResult {
        if let sessionID, try sessionIdentifier() != sessionID { throw KeychainFailure.locked }
        return try withWriteLock {
            var progress = KeychainImportResult()
            do {
                for row in source {
                    try cancellation?.check()
                    let existing: StoredRecord?
                    do {
                        existing = try record(service: row.service, id: row.id)
                    } catch KeychainFailure.status(errSecItemNotFound) {
                        existing = nil
                    }
                    try cancellation?.check()
                    if let existing {
                        if matches(existing, row) {
                            progress.skipped += 1
                            continue
                        }
                        guard replacingConflicts else {
                            progress.conflicts += 1
                            continue
                        }
                        try replace(row, secret: row.secret, previous: existing.modifiedAt)
                    } else {
                        try insert(row)
                    }
                    let saved = try record(service: row.service, id: row.id)
                    guard matches(saved, row) else { throw KeychainFailure.invalidRecord }
                    progress.imported += 1
                }
                return progress
            } catch {
                throw KeychainImportFailure(progress: progress, cause: error)
            }
        }
    }

    private func matches(_ lhs: StoredRecord, _ rhs: StoredRecord) -> Bool {
        lhs.id == rhs.id && lhs.service == rhs.service && lhs.label == rhs.label && lhs.generic == rhs.generic
            && (lhs.description ?? "") == (rhs.description ?? "") && (lhs.comment ?? "") == (rhs.comment ?? "")
            && lhs.secret == rhs.secret
    }

    private func read(service: String, id: UUID, includesSecret: Bool) throws -> StoredRecord {
        var query = try baseQuery(service: service, id: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        if includesSecret { query[kSecReturnData as String] = true }
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let attributes = result as? [String: Any] else { throw KeychainFailure.invalidRecord }
        return try decode(attributes, service: service, includesSecret: includesSecret)
    }

    private func decode(_ attributes: [String: Any], service: String, includesSecret: Bool) throws -> StoredRecord {
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let id = UUID(uuidString: account),
              let label = attributes[kSecAttrLabel as String] as? String,
              let generic = attributes[kSecAttrGeneric as String] as? Data,
              let date = attributes[kSecAttrModificationDate as String] as? Date else {
            throw KeychainFailure.invalidRecord
        }
        let secret: Data
        if includesSecret {
            guard let value = attributes[kSecValueData as String] as? Data else { throw KeychainFailure.invalidRecord }
            secret = value
        } else {
            secret = Data()
        }
        return StoredRecord(service: service, id: id, label: label, generic: generic,
                            description: attributes[kSecAttrDescription as String] as? String,
                            comment: attributes[kSecAttrComment as String] as? String,
                            modifiedAt: date, secret: secret)
    }

    private func itemAttributes(_ row: StoredRecord) -> [String: Any] {
        [kSecAttrLabel as String: row.label, kSecAttrGeneric as String: row.generic,
         kSecAttrDescription as String: row.description ?? "", kSecAttrComment as String: row.comment ?? ""]
    }

    private func insert(_ row: StoredRecord) throws {
        var query = try baseQuery(service: row.service, id: row.id, inserting: true)
        query.merge(itemAttributes(row)) { _, attribute in attribute }
        query[kSecValueData as String] = row.secret
        if usesDataProtection { query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly }
        try check(SecItemAdd(query as CFDictionary, nil))
    }

    private func replace(_ row: StoredRecord, secret: Data?, previous: Date) throws {
        let query = try baseQuery(service: row.service, id: row.id)
        var attributes = itemAttributes(row)
        if let secret { attributes[kSecValueData as String] = secret }
        // File-based Keychain records modification times in whole seconds.
        // Preserve distinct revisions for two edits to the same item within one clock tick.
        let nextSecond = floor(previous.timeIntervalSince1970) + 1
        let delay = nextSecond - Date.now.timeIntervalSince1970
        if delay > 0 && delay <= 1 { Thread.sleep(forTimeInterval: delay) }
        try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
    }

    private func baseQuery(service: String, id: UUID? = nil, inserting: Bool = false) throws -> [String: Any] {
        guard let session else { throw KeychainFailure.locked }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if usesDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrSynchronizable as String] = false
            query[kSecUseAuthenticationContext as String] = session.context
        } else if inserting {
            query[kSecUseKeychain as String] = try loginKeychain()
        } else {
            query[kSecMatchSearchList as String] = [try loginKeychain()]
        }
        if let id { query[kSecAttrAccount as String] = id.uuidString }
        return query
    }

    private func loginKeychain() throws -> SecKeychain {
        if let localKeychain { return localKeychain }
        let url: URL
        if let localKeychainURL {
            url = localKeychainURL
        } else {
            guard let home = getpwuid(getuid())?.pointee.pw_dir else { throw KeychainFailure.status(errSecNotAvailable) }
            url = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Keychains/login.keychain-db")
        }
        var result: SecKeychain?
        try check(SecKeychainOpen(url.path, &result))
        guard let result else { throw KeychainFailure.status(errSecNoSuchKeychain) }
        localKeychain = result
        return result
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw KeychainFailure.status(status) }
    }

    private func withWriteLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try requireUnlocked()
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let directory = open(lockDirectory.path, O_DIRECTORY | O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), fchmod(directory, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let fd = openat(directory, "keychain.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return try operation()
    }
}
