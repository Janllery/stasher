import Foundation

struct CSVImport: Sendable {
    struct Row: Sendable {
        let number: Int
        let credential: Credential
        let password: String
    }

    struct Plan {
        let ready: [Row]
        let duplicates: Int
        let invalidRows: [Int]

        var skipped: String {
            "Skipped \(duplicates) as duplicates and \(invalidRows.count) as invalid"
        }

        func excludingExisting(_ existing: [Credential]) -> Self {
            var known = Set(existing.map(Account.init))
            let unique = ready.filter { known.insert(Account($0.credential)).inserted }
            return Self(ready: unique, duplicates: duplicates + ready.count - unique.count,
                        invalidRows: invalidRows)
        }
    }

    private let rows: [Row]
    private let invalidRows: [Int]

    static func read(from url: URL) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sizeLimit = 10 * 1024 * 1024
        let data = try handle.read(upToCount: sizeLimit + 1) ?? Data()
        guard data.count <= sizeLimit else { throw Problem.tooLarge }
        guard let decoded = String(data: data, encoding: .utf8) else { throw Problem.encoding }
        let contents = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        return try parse(contents)
    }

    static func parse(_ contents: String) throws -> Self {
        let records = try records(in: contents)
        guard let header = records.first else { throw Problem.header }
        let labels = header.fields.map {
            String($0.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }

        func column(_ aliases: Set<String>, required: Bool = false) throws -> Int? {
            let matches = labels.indices.filter { aliases.contains(labels[$0]) }
            guard matches.count <= 1 else { throw Problem.duplicateHeader }
            if required && matches.isEmpty { throw Problem.header }
            return matches.first
        }

        let website = try column(["website", "websiteurl", "url", "loginuri", "網址", "網站網址"], required: true)
        let login = try column(["loginname", "username", "loginusername", "login", "登入名稱", "帳號"], required: true)
        let password = try column(["password", "loginpassword", "密碼"], required: true)
        let name = try column(["title", "name", "websitename", "網站名稱", "名稱"])
        let remarks = try column(["remarks", "notes", "note", "備註"])
        let category = try column(["category", "folder", "分類"])

        var rows: [Row] = []
        var invalidRows: [Int] = []
        for record in records.dropFirst() {
            func value(_ index: Int?) -> String {
                guard let index, record.fields.indices.contains(index) else { return "" }
                return record.fields[index]
            }

            var draft = CredentialDraft()
            draft.website = value(website)
            draft.loginName = value(login)
            draft.name = value(name)
            draft.remarks = value(remarks)
            draft.category = value(category)
            let secret = value(password)
            guard record.fields.count <= header.fields.count, let url = draft.websiteURL,
                  !draft.trimmedLoginName.isEmpty, !secret.isEmpty else {
                invalidRows.append(record.number)
                continue
            }
            rows.append(Row(number: record.number, credential: draft.metadata(id: UUID(), url: url),
                            password: secret))
        }
        return Self(rows: rows, invalidRows: invalidRows)
    }

    func plan(existing: [Credential]) -> Plan {
        Plan(ready: rows, duplicates: 0, invalidRows: invalidRows).excludingExisting(existing)
    }

    private struct Account: Hashable {
        let website: String
        let login: String

        init(_ credential: Credential) {
            login = credential.loginName
            guard var url = URLComponents(url: credential.url, resolvingAgainstBaseURL: false) else {
                website = credential.url.absoluteString
                return
            }
            url.scheme = url.scheme?.lowercased()
            url.host = url.host?.lowercased()
            url.fragment = nil
            if url.percentEncodedPath.isEmpty { url.percentEncodedPath = "/" }
            website = url.string ?? credential.url.absoluteString
        }
    }

    private struct Record {
        let number: Int
        let fields: [String]
    }

    private enum FieldState {
        case start, plain, quoted, closedQuote
    }

    private static func records(in source: String) throws -> [Record] {
        var rows: [Record] = []
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var state = FieldState.start
        var line = 1
        var recordLine = 1
        var previousWasCR = false

        func finishField() {
            fields.append(String(field))
            field.removeAll(keepingCapacity: true)
            state = .start
        }

        func finishRecord() {
            finishField()
            if fields.contains(where: { !$0.isEmpty }) {
                rows.append(Record(number: recordLine, fields: fields))
            }
            fields.removeAll(keepingCapacity: true)
        }

        for scalar in source.unicodeScalars {
            let isSecondInCRLF = scalar == "\n" && previousWasCR
            previousWasCR = scalar == "\r"
            if scalar == "\r" || scalar == "\n" {
                if !isSecondInCRLF { line += 1 }
                if state == .quoted {
                    field.append(scalar)
                } else if !isSecondInCRLF {
                    finishRecord()
                    recordLine = line
                }
                continue
            }

            switch (state, scalar) {
            case (.start, "\""):
                state = .quoted
            case (.quoted, "\""):
                state = .closedQuote
            case (.closedQuote, "\""):
                field.append(scalar)
                state = .quoted
            case (.quoted, _):
                field.append(scalar)
            case (_, ","):
                finishField()
            case (.closedQuote, _), (.plain, "\""):
                throw Problem.syntax(line)
            default:
                field.append(scalar)
                state = .plain
            }
        }
        if state == .quoted { throw Problem.syntax(recordLine) }
        finishRecord()
        return rows
    }

    enum Problem: LocalizedError {
        case header, duplicateHeader, encoding, tooLarge, syntax(Int)

        var errorDescription: String? {
            switch self {
            case .header:
                return "The CSV header must contain URL, Username, and Password columns."
            case .duplicateHeader:
                return "The CSV header maps more than one column to the same field. Keep one column per field."
            case .encoding:
                return "Save the CSV with UTF-8 encoding and try again."
            case .tooLarge:
                return "The CSV exceeds 10 MiB. Split it into smaller files and try again."
            case .syntax(let line):
                return "The CSV has invalid quoting on line \(line)."
            }
        }
    }
}
