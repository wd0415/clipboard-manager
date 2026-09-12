import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum ClipPayload: Codable, Equatable, Sendable {
    case text(String)
    case image(Data)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case text, image }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .image(let value):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .image: self = .image(try container.decode(Data.self, forKey: .value))
        }
    }
}

public struct ClipRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let payload: ClipPayload

    public init(id: UUID = UUID(), createdAt: Date = Date(), payload: ClipPayload) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
    }

    public var displayText: String {
        switch payload {
        case .text(let value): return value
        case .image: return "图片"
        }
    }
}

public final class ClipboardStore: @unchecked Sendable {
    public let directory: URL
    private let databaseURL: URL
    private var database: OpaquePointer?
    /// How many entries the store keeps. Fixed rather than adjustable: the history exists to make
    /// the last few copies reachable, and a limit the user can raise only makes the list longer to
    /// search by eye. Enforced by `trim()` at the end of every `insert`.
    public let maxEntries: Int

    public init(directory: URL, maxEntries: Int = 50) throws {
        guard maxEntries > 0 else { throw StoreError.invalidLimit }
        self.maxEntries = maxEntries
        self.directory = directory
        self.databaseURL = directory.appendingPathComponent("history.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw StoreError.database(Self.message(database))
        }
        do {
            try execute("""
                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY,
                    created_at REAL NOT NULL,
                    kind INTEGER NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS clips_created_at ON clips(created_at DESC);
                """)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public static func temporary(maxEntries: Int = 50) throws -> ClipboardStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-manager-\(UUID().uuidString)", isDirectory: true)
        return try ClipboardStore(directory: directory, maxEntries: maxEntries)
    }

    @discardableResult
    public func insert(_ payload: ClipPayload) throws -> ClipRecord {
        let record = ClipRecord(payload: payload)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("INSERT INTO clips (id, created_at, kind, payload) VALUES (?, ?, ?, ?)", &statement)
        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
        switch payload {
        case .text(let value):
            sqlite3_bind_int(statement, 3, 0)
            let data = Data(value.utf8)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), sqliteTransient) }
        case .image(let data):
            sqlite3_bind_int(statement, 3, 1)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), sqliteTransient) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.database(Self.message(database)) }
        try trim()
        return record
    }

    /// Moves an existing entry to the top of the history by refreshing its timestamp.
    ///
    /// Reusing an entry must not add a second row for content that is already stored, and the
    /// caller knows which row it picked, so this is a primary-key update rather than a scan.
    public func promote(id: UUID, at date: Date = Date()) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("UPDATE clips SET created_at = ? WHERE id = ?", &statement)
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.database(Self.message(database)) }
    }

    /// Removes one entry.
    ///
    /// Unlike `clear()` this is not confirmed: it is reached from the delete button on a single
    /// row, where the click itself is the intent and the blast radius is one row.
    public func delete(id: UUID) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("DELETE FROM clips WHERE id = ?", &statement)
        sqlite3_bind_text(statement, 1, id.uuidString, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.database(Self.message(database)) }
    }

    /// Removes every stored entry. Irreversible, so callers confirm before reaching here.
    public func clear() throws {
        try execute("DELETE FROM clips")
    }

    public func list(query: String? = nil) -> [ClipRecord] {
        let sql = query?.isEmpty == false
            ? "SELECT id, created_at, kind, payload FROM clips WHERE kind = 0 AND lower(CAST(payload AS TEXT)) LIKE lower(?) ORDER BY created_at DESC"
            : "SELECT id, created_at, kind, payload FROM clips ORDER BY created_at DESC"
        var statement: OpaquePointer?
        guard (try? prepare(sql, &statement)) != nil else { return [] }
        defer { sqlite3_finalize(statement) }
        if let query, !query.isEmpty { sqlite3_bind_text(statement, 1, "%\(query)%", -1, sqliteTransient) }
        var result: [ClipRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let record = record(from: statement) else { continue }
            result.append(record)
        }
        return result
    }

    private func trim() throws {
        try execute("DELETE FROM clips WHERE id NOT IN (SELECT id FROM clips ORDER BY created_at DESC LIMIT \(maxEntries))")
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? Self.message(database)
            sqlite3_free(errorMessage)
            throw StoreError.database(message)
        }
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.database(Self.message(database))
        }
    }

    private func record(from statement: OpaquePointer?) -> ClipRecord? {
        guard let idText = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: idText)) else { return nil }
        let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        let kind = sqlite3_column_int(statement, 2)
        let length = sqlite3_column_bytes(statement, 3)
        guard let bytes = sqlite3_column_blob(statement, 3) else { return nil }
        let data = Data(bytes: bytes, count: Int(length))
        let payload: ClipPayload = kind == 0 ? .text(String(decoding: data, as: UTF8.self)) : .image(data)
        return ClipRecord(id: id, createdAt: date, payload: payload)
    }

    private static func message(_ database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

public enum StoreError: Error, Equatable {
    case invalidLimit
    case database(String)
}
