import Contacts
import Foundation
import Security

enum WalletKind: Hashable, Sendable {
    case address, card

    var title: String { self == .address ? "Addresses" : "Cards" }
    var icon: String { self == .address ? "mappin.and.ellipse" : "creditcard" }
    var service: String {
        switch self {
        case .address: "local.passwordreminder.addresses.v1"
        case .card: "local.passwordreminder.cards.v1"
        }
    }

    var fieldRows: [[WalletField]] {
        switch self {
        case .address:
            [[.recipient, .phone], [.country], [.street], [.unit], [.city, .region], [.postalCode]]
        case .card:
            [[.cardholder], [.number], [.expiration, .securityCode]]
        }
    }

    var detailFields: [WalletField] {
        switch self {
        case .address: [.recipient, .street, .unit, .city, .region, .postalCode, .country, .phone]
        case .card: [.cardholder, .number, .expiration, .securityCode]
        }
    }
}

enum WalletField: String, Codable, Hashable, Sendable {
    case recipient, phone, country, street, unit, city, region, postalCode
    case cardholder, number, expiration, securityCode

    var title: String {
        switch self {
        case .recipient: "Recipient"
        case .phone: "Phone"
        case .country: "Country or region"
        case .street: "Address line 1"
        case .unit: "Address line 2"
        case .city: "City or district"
        case .region: "State or province"
        case .postalCode: "Postal code"
        case .cardholder: "Cardholder name"
        case .number: "Card number"
        case .expiration: "Expiry date"
        case .securityCode: "Security code (CVV)"
        }
    }

    var isMasked: Bool { self == .number || self == .securityCode }

    var isRequired: Bool {
        switch self {
        case .country, .street, .cardholder, .number, .expiration: true
        default: false
        }
    }

    var placeholder: String {
        switch self {
        case .number: "Enter card number"
        case .expiration: "MM/YY"
        case .securityCode: "3 or 4 digits"
        default: ""
        }
    }
}

struct WalletSummary: Identifiable, Sendable {
    let id: UUID
    let kind: WalletKind
    let label: String
    let hint: String
    var modifiedAt: Date? = nil

    var subtitle: String {
        switch kind {
        case .address: Country.name(hint)
        case .card: "•••• \(hint)"
        }
    }
}

struct WalletRecord: Sendable {
    let summary: WalletSummary
    let fields: [WalletField: String]

    func value(_ field: WalletField) -> String {
        let text = fields[field] ?? ""
        return field == .country && !text.isEmpty ? Country.name(text) : text
    }

    func display(_ field: WalletField) -> String {
        let text = value(field)
        guard !text.isEmpty, field.isMasked else { return text }
        return field == .number ? "•••• \(text.suffix(4))" : String(repeating: "•", count: text.count)
    }

    var mailingAddress: String {
        let address = CNMutablePostalAddress()
        address.street = [value(.street), value(.unit)].filter { !$0.isEmpty }.joined(separator: "\n")
        address.city = value(.city)
        address.state = value(.region)
        address.postalCode = value(.postalCode)
        address.country = value(.country)
        address.isoCountryCode = fields[.country] ?? ""
        let formatted = CNPostalAddressFormatter.string(from: address, style: .mailingAddress)
        return [value(.recipient), formatted].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct WalletDraft {
    var label = ""
    var fields: [WalletField: String] = [:]

    init(kind: WalletKind, record: WalletRecord? = nil) {
        if let record {
            label = record.summary.label
            fields = record.fields
        } else if kind == .address {
            if let region = Locale.current.region?.identifier, Country.codes.contains(region) {
                fields[.country] = region
            }
        }
    }

    func record(kind: WalletKind, id: UUID = UUID()) throws -> WalletRecord {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WalletInputError("Enter a label.") }
        var values: [WalletField: String] = [:]
        for field in kind.detailFields {
            let text = (fields[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if field.isRequired, text.isEmpty { throw WalletInputError("Enter \(field.title.lowercased()).") }
            if !text.isEmpty { values[field] = text }
        }

        let hint: String
        switch kind {
        case .address:
            guard let country = values[.country], Country.codes.contains(country) else {
                throw WalletInputError("Choose a country or region.")
            }
            hint = country
        case .card:
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-"))
            let number = (values[.number] ?? "").components(separatedBy: separators).joined()
            guard (8...19).contains(number.count), Self.isASCIIDigits(number) else {
                throw WalletInputError("Enter a valid card number.")
            }
            let expiration = (values[.expiration] ?? "").split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard expiration.count == 2,
                  (1...2).contains(expiration[0].count), Self.isASCIIDigits(expiration[0]),
                  let month = Int(expiration[0]), (1...12).contains(month),
                  [2, 4].contains(expiration[1].count), Self.isASCIIDigits(expiration[1]) else {
                throw WalletInputError("Enter the expiry date as MM/YY or MM/YYYY.")
            }
            if let code = values[.securityCode], ![3, 4].contains(code.count) || !Self.isASCIIDigits(code) {
                throw WalletInputError("Enter 3 or 4 digits for the security code.")
            }
            values[.number] = number
            values[.expiration] = String(format: "%02d", month) + "/" + expiration[1].suffix(2)
            hint = String(number.suffix(4))
        }
        return WalletRecord(summary: WalletSummary(id: id, kind: kind, label: name, hint: hint), fields: values)
    }

    private static func isASCIIDigits(_ value: String) -> Bool {
        value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

struct WalletInputError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum Country {
    static let codes = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 })
    static let sortedCodes = codes.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }
}

struct WalletStore: Sendable {
    private let database: KeychainDatabase

    init(database: KeychainDatabase = .shared) {
        self.database = database
    }

    func list(_ kind: WalletKind) async throws -> [WalletSummary] {
        try await database.records(service: kind.service).map { row in
            try Self.summary(for: row, kind: kind)
        }
    }

    private static func summary(for row: StoredRecord, kind: WalletKind) throws -> WalletSummary {
        guard let hint = String(data: row.generic, encoding: .utf8) else { throw KeychainFailure.invalidRecord }
        return WalletSummary(id: row.id, kind: kind, label: row.label, hint: hint, modifiedAt: row.modifiedAt)
    }

    func read(_ summary: WalletSummary) async throws -> WalletRecord {
        let row = try await database.record(service: summary.kind.service, id: summary.id)
        if let revision = summary.modifiedAt, row.modifiedAt != revision { throw KeychainFailure.changed }
        let current = try Self.record(for: row, kind: summary.kind)
        guard current.summary.label == summary.label, current.summary.hint == summary.hint else {
            throw KeychainFailure.changed
        }
        return current
    }

    static func validateLegacyRecord(_ row: StoredRecord) throws {
        guard let kind = [WalletKind.address, .card].first(where: { $0.service == row.service }) else {
            throw KeychainFailure.invalidRecord
        }
        _ = try record(for: row, kind: kind)
    }

    private static func record(for row: StoredRecord, kind: WalletKind) throws -> WalletRecord {
        guard let fields = try? JSONDecoder().decode([WalletField: String].self, from: row.secret) else {
            throw KeychainFailure.invalidRecord
        }
        return WalletRecord(summary: try summary(for: row, kind: kind), fields: fields)
    }

    @discardableResult
    func save(_ record: WalletRecord, editing: Bool, expectedModifiedAt: Date? = nil) async throws -> WalletRecord {
        let summary = record.summary
        let data = try JSONEncoder().encode(record.fields)
        let generic = Data(summary.hint.utf8)
        let row: StoredRecord
        if editing {
            row = try await database.update(service: summary.kind.service, id: summary.id, label: summary.label,
                                            generic: generic, description: nil, comment: nil, secret: data,
                                            expectedModifiedAt: expectedModifiedAt)
        } else {
            let item = StoredRecord(service: summary.kind.service, id: summary.id, label: summary.label,
                                    generic: generic, description: nil, comment: nil, modifiedAt: .now, secret: data)
            row = try await database.add(item)
        }
        return WalletRecord(summary: try Self.summary(for: row, kind: summary.kind), fields: record.fields)
    }

    func delete(_ summary: WalletSummary) async throws {
        try await database.delete(service: summary.kind.service, id: summary.id, expectedModifiedAt: summary.modifiedAt)
    }
}
