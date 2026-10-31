import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite error \(code): \(message)" }
}

public enum SQLiteValue: Sendable, Equatable {
    case int(Int64)
    case text(String)
    case null
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let error = SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? lastMessage()
            sqlite3_free(message)
            throw SQLiteError(code: rc, message: text)
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        do {
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func query(_ sql: String, _ binds: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw SQLiteError(code: prepared, message: lastMessage())
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in binds.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case .int(let v): rc = sqlite3_bind_int64(statement, position, v)
            case .text(let v): rc = sqlite3_bind_text(statement, position, v, -1, sqliteTransient)
            case .null: rc = sqlite3_bind_null(statement, position)
            }
            guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: lastMessage()) }
        }

        var rows: [[SQLiteValue]] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: lastMessage()) }
            var row: [SQLiteValue] = []
            row.reserveCapacity(Int(columns))
            for column in 0..<columns {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    row.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_TEXT:
                    row.append(.text(String(cString: sqlite3_column_text(statement, column))))
                default:
                    row.append(.null)
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    private func lastMessage() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }
}
