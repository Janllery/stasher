import Foundation

enum VaultMigration {
    static func importAll(password: String, cancellation: CancellationToken? = nil,
                          archive: EncryptedVaultArchive = EncryptedVaultArchive(),
                          database: KeychainDatabase = .shared) async throws -> KeychainImportResult {
        try cancellation?.check()
        let session = try await database.sessionIdentifier()
        let contents = try await archive.read(password: password)
        try cancellation?.check()
        for record in contents.records {
            if record.service == CredentialStore.service {
                try CredentialStore.validateLegacyRecord(record)
            } else {
                try WalletStore.validateLegacyRecord(record)
            }
        }
        guard try await database.sessionIdentifier() == session else { throw KeychainFailure.locked }
        let result = try await database.importRecords(contents.records, cancellation: cancellation, sessionID: session)
        try cancellation?.check()
        _ = try await database.rememberCategories(Array(contents.categorySlots.keys),
                                                 legacySlots: contents.categorySlots)
        return result
    }
}
