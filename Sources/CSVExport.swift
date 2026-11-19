import Foundation

struct CSVExport: Sendable {
    private var data = Data("\u{FEFF}URL,Username,Password,Title,Notes,Category\r\n".utf8)

    mutating func append(_ entry: Credential, password: String) {
        let fields = [entry.url.absoluteString, entry.loginName, password, entry.name, entry.remarks, entry.category]
        let line = fields.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ",")
        data.append(contentsOf: line.utf8)
        data.append(contentsOf: "\r\n".utf8)
    }

    func write(to url: URL, cancellation: CancellationToken? = nil) throws {
        let permission = cancellation ?? CancellationToken()
        try permission.withPermission {}
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let files = FileManager.default
        let directory = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: url, create: true)
        defer { try? files.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("Export.csv")
        guard files.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try permission.withPermission {
            if files.fileExists(atPath: url.path) {
                _ = try files.replaceItemAt(url, withItemAt: staged, options: .usingNewMetadataOnly)
            } else {
                try files.moveItem(at: staged, to: url)
            }
        }
    }
}
