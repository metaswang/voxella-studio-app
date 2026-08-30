import Foundation
import SQLite3
import CSQLiteVec

enum SessionSQLiteError: Error, Equatable {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case unexpectedNull
}

final class SessionSQLite: @unchecked Sendable {
    private var db: OpaquePointer?

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw SessionSQLiteError.openFailed(Self.message(handle))
        }
        db = handle
        sqlite_vec_register_db(handle)
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA busy_timeout = 5000;")
    }

    deinit {
        sqlite3_close(db)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        if let error {
            let message = String(cString: error)
            sqlite3_free(error)
            if status != SQLITE_OK { throw SessionSQLiteError.execFailed(message) }
        } else if status != SQLITE_OK {
            throw SessionSQLiteError.execFailed(Self.message(db))
        }
    }

    @discardableResult
    func run(_ sql: String, binds: [SessionSQLiteValue] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SessionSQLiteError.stepFailed(Self.message(db))
        }
        return Int(sqlite3_last_insert_rowid(db))
    }

    func query(_ sql: String, binds: [SessionSQLiteValue] = []) throws -> [SessionSQLiteRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, binds)
        var rows: [SessionSQLiteRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw SessionSQLiteError.stepFailed(Self.message(db))
            }
            rows.append(SessionSQLiteRow(statement: statement))
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw SessionSQLiteError.prepareFailed(Self.message(db))
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [SessionSQLiteValue]) throws {
        for (index, value) in values.enumerated() {
            let slot = Int32(index + 1)
            let status: Int32
            switch value {
            case .null:
                status = sqlite3_bind_null(statement, slot)
            case .int(let number):
                status = sqlite3_bind_int64(statement, slot, number)
            case .double(let number):
                status = sqlite3_bind_double(statement, slot, number)
            case .text(let text):
                status = sqlite3_bind_text(statement, slot, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                status = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        slot,
                        bytes.baseAddress,
                        Int32(data.count),
                        SQLITE_TRANSIENT
                    )
                }
            }
            guard status == SQLITE_OK else {
                throw SessionSQLiteError.prepareFailed(Self.message(db))
            }
        }
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let db else { return "SQLite error" }
        return String(cString: sqlite3_errmsg(db))
    }
}

enum SessionSQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func int(_ value: Int) -> SessionSQLiteValue { .int(Int64(value)) }
    static func bool(_ value: Bool) -> SessionSQLiteValue { .int(value ? 1 : 0) }
    static func optional(_ value: String?) -> SessionSQLiteValue {
        value.map { .text($0) } ?? .null
    }
    static func optional(_ value: Double?) -> SessionSQLiteValue {
        value.map { .double($0) } ?? .null
    }
    static func optional(_ value: Int?) -> SessionSQLiteValue {
        value.map { .int(Int64($0)) } ?? .null
    }
}

struct SessionSQLiteRow {
    private let columns: [String: SessionSQLiteValue]

    init(statement: OpaquePointer) {
        var columns: [String: SessionSQLiteValue] = [:]
        let count = sqlite3_column_count(statement)
        for index in 0..<count {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                columns[name] = .int(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                columns[name] = .double(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                if let pointer = sqlite3_column_text(statement, index) {
                    columns[name] = .text(String(cString: pointer))
                } else {
                    columns[name] = .null
                }
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(statement, index) {
                    let length = Int(sqlite3_column_bytes(statement, index))
                    columns[name] = .blob(Data(bytes: bytes, count: length))
                } else {
                    columns[name] = .null
                }
            default:
                columns[name] = .null
            }
        }
        self.columns = columns
    }

    func int(_ name: String) -> Int? {
        if case .int(let value) = columns[name] { return Int(value) }
        return nil
    }

    func double(_ name: String) -> Double? {
        switch columns[name] {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    func text(_ name: String) -> String? {
        if case .text(let value) = columns[name] { return value }
        return nil
    }

    func bool(_ name: String) -> Bool {
        int(name) == 1
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
