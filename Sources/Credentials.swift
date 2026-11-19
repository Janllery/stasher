import Foundation
import Security

struct Credential: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let url: URL
    let loginName: String
    let remarks: String
    let category: String
    let modifiedAt: Date

    var domain: String { url.host() ?? url.absoluteString }
}

struct CredentialDraft {
    var website = ""
    var name = ""
    var loginName = ""
    var password = ""
    var remarks = ""
    var category = ""

    init(credential: Credential? = nil) {
        if let credential {
            website = credential.url.absoluteString
            name = credential.name
            loginName = credential.loginName
            remarks = credential.remarks
            category = credential.category
        }
    }

    var websiteURL: URL? {
        let text = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        let normalized = text.contains("://") ? text : "https://\(text)"
        guard let parts = URLComponents(string: normalized),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else {
            return nil
        }
        return parts.url
    }

    var trimmedLoginName: String { loginName.trimmingCharacters(in: .whitespacesAndNewlines) }

    func metadata(id: UUID, url: URL) -> Credential {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Credential(id: id, name: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                          url: url, loginName: trimmedLoginName, remarks: remarks,
                          category: category.trimmingCharacters(in: .whitespacesAndNewlines), modifiedAt: .now)
    }
}

private struct WebsiteMetadata: Codable {
    let url: URL
    let category: String

    init(url: URL, category: String) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false), !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              url.user == nil, url.password == nil else {
            throw KeychainFailure.invalidRecord
        }
        self.url = url
        self.category = category
    }

    init(data: Data) throws {
        if let metadata = try? JSONDecoder().decode(Self.self, from: data) {
            try self.init(url: metadata.url, category: metadata.category)
            return
        }
        // Releases before categories stored the plain website URL.
        guard let string = String(data: data, encoding: .utf8), let url = URL(string: string) else {
            throw KeychainFailure.invalidRecord
        }
        try self.init(url: url, category: "")
    }

    func encoded() throws -> Data {
        if category.isEmpty { return Data(url.absoluteString.utf8) }
        return try JSONEncoder().encode(self)
    }
}

enum KeychainFailure: LocalizedError {
    case status(OSStatus)
    case invalidRecord
    case clipboard, locked, changed

    var canceled: Bool {
        if case .status(errSecUserCanceled) = self { return true }
        return false
    }

    var invalidatesAuthentication: Bool {
        switch self {
        case .status(errSecAuthFailed), .status(errSecInteractionNotAllowed), .status(errSecNotAvailable):
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .status(errSecUserCanceled):
            return "Authentication canceled."
        case .status(errSecItemNotFound):
            return "This item no longer exists."
        case .status(errSecMissingEntitlement):
            return "macOS did not authorize this build to access the Keychain (-34018)."
        case .status(errSecNotAvailable):
            return "The Keychain is unavailable (-25291). Sign in and unlock your Mac, then try again."
        case .status(errSecAuthFailed), .status(errSecInteractionNotAllowed):
            return "macOS could not verify your identity. Unlock your Mac and try again."
        case .status(let status):
            return "The Keychain operation failed (\(status))."
        case .invalidRecord:
            return "Could not read this Keychain item."
        case .locked:
            return "Unlock with your Mac to continue."
        case .changed:
            return "This record changed in another window. Refresh and select it again."
        case .clipboard:
            return "Could not write to the clipboard."
        }
    }
}

struct CredentialStore: Sendable {
    static let service = "local.passwordreminder.entries.v1"
    private let database: KeychainDatabase

    init(database: KeychainDatabase = .shared) {
        self.database = database
    }

    func list() async throws -> [Credential] {
        try await database.records(service: Self.service).map(Self.credential)
    }

    func exportRows(cancellation: CancellationToken? = nil) async throws -> [(entry: Credential, password: String)] {
        try await database.exportRecords(service: Self.service, cancellation: cancellation).map { row in
            try (Self.credential(row), Self.decodePassword(row.secret))
        }
    }

    static func validateLegacyRecord(_ row: StoredRecord) throws {
        guard row.service == service else { throw KeychainFailure.invalidRecord }
        _ = try credential(row)
        _ = try decodePassword(row.secret)
    }

    private static func credential(_ row: StoredRecord) throws -> Credential {
        let website = try WebsiteMetadata(data: row.generic)
        return Credential(id: row.id, name: row.label, url: website.url,
                          loginName: row.description ?? "", remarks: row.comment ?? "",
                          category: website.category, modifiedAt: row.modifiedAt)
    }

    @discardableResult
    func add(_ entry: Credential, password: String) async throws -> Credential {
        let generic = try WebsiteMetadata(url: entry.url, category: entry.category).encoded()
        let record = StoredRecord(service: Self.service, id: entry.id, label: entry.name, generic: generic,
                                  description: entry.loginName, comment: entry.remarks,
                                  modifiedAt: entry.modifiedAt, secret: Data(password.utf8))
        let row = try await database.add(record)
        return try Self.credential(row)
    }

    @discardableResult
    func update(_ entry: Credential, password: String?, expectedModifiedAt: Date? = nil) async throws -> Credential {
        let row = try await database.update(service: Self.service, id: entry.id, label: entry.name,
                                            generic: WebsiteMetadata(url: entry.url, category: entry.category).encoded(),
                                            description: entry.loginName, comment: entry.remarks,
                                            secret: password.map { Data($0.utf8) }, expectedModifiedAt: expectedModifiedAt)
        return try Self.credential(row)
    }

    func password(for entry: Credential) async throws -> String {
        let row = try await database.record(service: Self.service, id: entry.id)
        guard try Self.credential(row) == entry else { throw KeychainFailure.changed }
        return try Self.decodePassword(row.secret)
    }

    private static func decodePassword(_ data: Data) throws -> String {
        guard let password = String(data: data, encoding: .utf8) else { throw KeychainFailure.invalidRecord }
        return password
    }

    func delete(_ entry: Credential) async throws {
        try await database.delete(service: Self.service, id: entry.id, expectedModifiedAt: entry.modifiedAt)
    }
}
