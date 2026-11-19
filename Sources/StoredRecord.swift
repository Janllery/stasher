import Foundation

struct StoredRecord: Codable, Sendable, Equatable {
    let service: String
    let id: UUID
    var label: String
    var generic: Data
    var description: String?
    var comment: String?
    var modifiedAt: Date
    var secret: Data
}
