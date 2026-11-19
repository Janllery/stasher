import CommonCrypto
import CryptoKit
import Darwin
import Foundation

enum ArchiveFailure: LocalizedError {
    case missing, invalidFile, unsupportedVersion, authentication

    var errorDescription: String? {
        switch self {
        case .missing: "No encrypted vault was found. Your existing Keychain data is already available."
        case .invalidFile: "Could not read the encrypted vault. Keep the original file and check your backup."
        case .unsupportedVersion: "This encrypted vault uses an unsupported format."
        case .authentication: "Could not open the encrypted vault. Check its master password and file."
        }
    }
}

struct VaultArchiveContents: Sendable {
    let records: [StoredRecord]
    let categorySlots: [String: Int]
}

// Compatibility reader for encrypted files created by pre-release builds.
actor EncryptedVaultArchive {
    static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.passwordreminder.app", isDirectory: true)
        .appendingPathComponent("vault.stasher")

    private struct Header: Decodable {
        let magic: String
        let version: Int
        let kdf: String
        let iterations: UInt32
        let salt: Data
    }

    private struct Envelope: Decodable {
        let header: Data
        let sealed: Data
    }

    private struct Payload: Decodable {
        let records: [StoredRecord]
        let categorySlots: [String: Int]?

        var contents: VaultArchiveContents {
            VaultArchiveContents(records: records, categorySlots: categorySlots ?? [:])
        }
    }

    private let url: URL

    init(url: URL = defaultURL) {
        self.url = url
    }

    func read(password: String) throws -> VaultArchiveContents {
        let data = try readFile()
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.header.count < 4096, envelope.sealed.count >= 28,
              let header = try? JSONDecoder().decode(Header.self, from: envelope.header),
              header.magic == "StasherVault", header.salt.count == 16,
              (600_000...2_000_000).contains(header.iterations) else {
            throw ArchiveFailure.invalidFile
        }
        guard [1, 2].contains(header.version), header.kdf == "PBKDF2-HMAC-SHA256" else {
            throw ArchiveFailure.unsupportedVersion
        }
        var candidates = [password]
        if header.version == 1 {
            candidates += [password.precomposedStringWithCanonicalMapping, password.decomposedStringWithCanonicalMapping]
        }
        var tried: Set<Data> = []
        for candidate in candidates {
            guard tried.insert(Data(candidate.utf8)).inserted else { continue }
            let key = try deriveKey(password: candidate, header: header)
            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(combined: envelope.sealed)
                plaintext = try AES.GCM.open(box, using: key, authenticating: envelope.header)
            } catch {
                continue
            }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: plaintext) else {
                throw ArchiveFailure.invalidFile
            }
            var identities: Set<String> = []
            for record in payload.records {
                guard identities.insert(record.service + "\0" + record.id.uuidString).inserted else {
                    throw ArchiveFailure.invalidFile
                }
            }
            return payload.contents
        }
        throw ArchiveFailure.authentication
    }

    private func readFile() throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw ArchiveFailure.missing }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid(),
              information.st_size <= 128 * 1024 * 1024 else { throw ArchiveFailure.invalidFile }
        let data = try handle.read(upToCount: 128 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 128 * 1024 * 1024 else { throw ArchiveFailure.invalidFile }
        return data
    }

    private func deriveKey(password: String, header: Header) throws -> SymmetricKey {
        let text = header.version >= 2 ? password.precomposedStringWithCanonicalMapping : password
        var bytes = Array(text.utf8)
        var key = [UInt8](repeating: 0, count: 32)
        defer {
            _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        let count = bytes.count
        let status = bytes.withUnsafeBytes { passwordBuffer in
            header.salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.bindMemory(to: Int8.self).baseAddress, count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, saltBuffer.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), header.iterations, &key, key.count)
            }
        }
        guard status == kCCSuccess else { throw ArchiveFailure.invalidFile }
        return SymmetricKey(data: key)
    }
}
