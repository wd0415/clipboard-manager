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

@Test func pinnedEntriesSortAheadOfTheRecentOnes() throws {
    let store = try ClipboardStore.temporary()
    let older = try store.insert(.text("older"))
    let newer = try store.insert(.text("newer"))
    _ = try store.setPinned(true, id: older.id)

    // The pinned entry leads despite being the older of the two; the recent entries keep their
    // own timestamp order behind it.
    #expect(store.list().map(\.id) == [older.id, newer.id])
    #expect(store.list().map(\.isPinned) == [true, false])
}

@Test func thePinFlagSurvivesReopeningTheDatabase() throws {
    let store = try ClipboardStore.temporary()
    let pinned = try store.insert(.text("stays"))
    let recent = try store.insert(.text("drifts"))
    _ = try store.setPinned(true, id: pinned.id)

    let reopened = try ClipboardStore(directory: store.directory)

    #expect(reopened.list().map(\.id) == [pinned.id, recent.id])
    #expect(reopened.list().first?.isPinned == true)
}

@Test func pinningExemptsAnEntryFromTheFiftyEntryCap() throws {
    let store = try ClipboardStore.temporary(maxEntries: 3)
    let oldest = try store.insert(.text("oldest"))
    _ = try store.insert(.text("second"))
    _ = try store.insert(.text("third"))
    _ = try store.setPinned(true, id: oldest.id)
    // Every insert trims, so the pinned entry has to survive two more of them.
    _ = try store.insert(.text("fourth"))
    _ = try store.insert(.text("fifth"))

    let stored = store.list()
    // Three recent entries plus the pinned one, not three in total.
    #expect(stored.count == 4)
    #expect(stored.first?.id == oldest.id)
    #expect(stored.dropFirst().map(\.displayText) == ["fifth", "fourth", "third"])
}

@Test func unpinningReturnsAnEntryToTheRecentCap() throws {
    let store = try ClipboardStore.temporary(maxEntries: 2)
    let oldest = try store.insert(.text("oldest"))
    _ = try store.insert(.text("second"))
    _ = try store.setPinned(true, id: oldest.id)
    // Pinning leads the list even though it is the older of the two.
    #expect(store.list().map(\.displayText) == ["oldest", "second"])

    _ = try store.setPinned(false, id: oldest.id)
    _ = try store.insert(.text("third"))    // the trim that now reaches it

    // Unpinning puts it back on the eviction train rather than exempting it forever.
    #expect(store.list().map(\.displayText) == ["third", "second"])
}

@Test func pinningIsRefusedOnceTheBoardIsFull() throws {
    let store = try ClipboardStore.temporary()
    let records = try (0..<6).map { try store.insert(.text("entry \($0)")) }

    for record in records.prefix(5) {
        #expect(try store.setPinned(true, id: record.id) == .pinned)
    }

    #expect(try store.setPinned(true, id: records[5].id) == .refusedBoardIsFull)
    #expect(store.list().filter(\.isPinned).count == 5)
}

@Test func promotingAPinnedEntryMovesItWithinThePinnedSection() throws {
    let store = try ClipboardStore.temporary()
    let first = try store.insert(.text("first pinned"))
    let second = try store.insert(.text("second pinned"))
    _ = try store.setPinned(true, id: first.id)
    _ = try store.setPinned(true, id: second.id)
    #expect(store.list().map(\.id) == [second.id, first.id])

    try store.promote(id: first.id)

    // Reusing an entry moves it inside the pinboard without duplicating it and without promoting
    // it into the recent section.
    #expect(store.list().map(\.id) == [first.id, second.id])
    #expect(store.list().count == 2)
}
