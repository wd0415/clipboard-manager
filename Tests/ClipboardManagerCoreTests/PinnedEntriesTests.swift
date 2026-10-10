import Foundation
import SQLite3
import Testing
@testable import ClipboardManagerCore

@Test func addingThePinColumnToAnExistingDatabaseKeepsItsRows() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipboard-legacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // The four-column shape a build from before pinning created. `CREATE TABLE IF NOT EXISTS`
    // leaves a table that already exists completely alone, so without the ALTER step below
    // every one of these rows becomes unreadable the moment the store opens the file — and
    // nothing reports it, because `list()` swallows a failed prepare and answers `[]`.
    let id = UUID().uuidString
    var legacy: OpaquePointer?
    let url = directory.appendingPathComponent("history.sqlite3")
    try #require(
        sqlite3_open_v2(url.path, &legacy, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
    )
    defer { sqlite3_close(legacy) }
    try #require(
        sqlite3_exec(
            legacy,
            "CREATE TABLE clips (id TEXT PRIMARY KEY, created_at REAL NOT NULL, kind INTEGER NOT NULL, payload BLOB NOT NULL)",
            nil, nil, nil
        ) == SQLITE_OK
    )
    try #require(
        sqlite3_exec(
            legacy,
            "INSERT INTO clips (id, created_at, kind, payload) VALUES ('\(id)', 1, 0, CAST('kept' AS BLOB))",
            nil, nil, nil
        ) == SQLITE_OK
    )

    let store = try ClipboardStore(directory: directory)

    #expect(store.list().map(\.displayText) == ["kept"])
}
