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
    /// Whether the entry is pinned to a section of its own at the top of the history. This is a
    /// property of the entry rather than a position: the ordinal the menu draws is derived from
    /// `createdAt`, and a pinned entry has deliberately left that sequence.
    public let isPinned: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        payload: ClipPayload,
        isPinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
        self.isPinned = isPinned
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
    /// How many entries may be pinned at once. Fixed rather than adjustable for the same reason
    /// `maxEntries` is: the pinboard is the handful of entries always worth reaching, and a board
    /// that grows without bound stops being one. Enforced here rather than in the UI so that it is
    /// a property of the store and can be tested.
    public let maxPinnedEntries: Int = 5

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
                    payload BLOB NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS clips_created_at ON clips(created_at DESC);
                """)
            try addPinColumnIfMissing()
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

    /// Pins or unpins an entry, exempting it from the entry cap while it is pinned.
    ///
    /// Refuses rather than throwing when the board is full, and never drops an existing pin to
    /// make room: which entry loses its place is the user's decision, not a side effect of pinning
    /// something else.
    @discardableResult
    public func setPinned(_ pinned: Bool, id: UUID) throws -> PinOutcome {
        if pinned, try pinnedCount(excluding: id) >= maxPinnedEntries {
            return .refusedBoardIsFull
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("UPDATE clips SET pinned = ? WHERE id = ?", &statement)
        sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
        sqlite3_bind_text(statement, 2, id.uuidString, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.database(Self.message(database)) }
        return pinned ? .pinned : .unpinned
    }

    /// Counts the pinned entries other than `id`, so that pinning something already pinned is not
    /// treated as a second entry's worth of demand on a full board.
    private func pinnedCount(excluding id: UUID) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("SELECT COUNT(*) FROM clips WHERE pinned = 1 AND id <> ?", &statement)
        sqlite3_bind_text(statement, 1, id.uuidString, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
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
            ? "SELECT id, created_at, kind, payload, pinned FROM clips WHERE kind = 0 AND lower(CAST(payload AS TEXT)) LIKE lower(?) ORDER BY pinned DESC, created_at DESC"
            : "SELECT id, created_at, kind, payload, pinned FROM clips ORDER BY pinned DESC, created_at DESC"
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

    /// Adds the `pinned` column to a database created before pinning existed.
    ///
    /// `CREATE TABLE IF NOT EXISTS` does not touch a table that already exists, so an installed
    /// database keeps the four-column shape it was created with — and `list()` answers a failed
    /// prepare with `[]`, so reading `pinned` against one fails as an *empty history* rather than
    /// as an error. A fresh database already has the column, so this is a no-op there; an existing
    /// one has it appended, which leaves the physical column order the same either way.
    ///
    /// Probing `table_info` rather than catching "duplicate column name" keeps the correctness off
    /// SQLite's English error strings.
    private func addPinColumnIfMissing() throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare("PRAGMA table_info(clips)", &statement)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == "pinned" { return }
        }
        try execute("ALTER TABLE clips ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
    }

    /// Keeps the newest `maxEntries` unpinned rows plus every pinned one.
    ///
    /// The cap counts recent entries only: pinning is a decision to keep something past its
    /// moment, and letting that decision shorten the recent list would mean the price of pinning
    /// is paid by the entries the user did not pin. The ids come from the subquery itself rather
    /// than from a caller's string, so the case-sensitivity trap around `UUID.uuidString` — which
    /// this codebase has been bitten by — does not apply here.
    private func trim() throws {
        try execute("DELETE FROM clips WHERE pinned = 0 AND id NOT IN (SELECT id FROM clips WHERE pinned = 0 ORDER BY created_at DESC LIMIT \(maxEntries))")
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
        return ClipRecord(id: id, createdAt: date, payload: payload, isPinned: sqlite3_column_int(statement, 4) != 0)
    }

    private static func message(_ database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

/// What `setPinned` did. A full pinboard is a refusal rather than a failure, because the caller is
/// expected to show it and carry on — throwing would collapse "pinned" and "could not pin" into
/// one `catch`, and the UI could then no longer tell the user which happened.
public enum PinOutcome: Equatable, Sendable {
    case pinned
    case unpinned
    case refusedBoardIsFull
}

public enum StoreError: Error, Equatable {
    case invalidLimit
    case database(String)
}
