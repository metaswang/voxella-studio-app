import Foundation

struct CredentialMigration {
    struct Record: Codable, Equatable {
        var value: String?
    }

    let read: () throws -> Record?
    let write: (Record) throws -> Void
    let readLegacy: () throws -> String?
    let removeLegacy: () throws -> Void

    func load() throws -> String? {
        if let record = try read() { return record.value }
        guard let value = try readLegacy() else { return nil }
        try write(Record(value: value))
        try removeLegacy()
        return value
    }

    func save(_ value: String) throws {
        try write(Record(value: value))
        try removeLegacy()
    }

    func delete() throws {
        try write(Record(value: nil))
        try removeLegacy()
    }
}
