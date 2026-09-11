import Foundation
import Testing
@testable import ClipboardManagerCore

@Test func storesTextAndReturnsNewestFirst() throws {
    let store = try ClipboardStore.temporary()
    let older = try store.insert(.text("older"))
    let newer = try store.insert(.text("newer"))

    #expect(store.list().map(\.id) == [newer.id, older.id])
    #expect(store.list().first?.displayText == "newer")
}

@Test func persistsAcrossStoreInstances() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try ClipboardStore(directory: directory).insert(.text("persisted"))
    let reopened = try ClipboardStore(directory: directory)

    #expect(reopened.list().map(\.displayText) == ["persisted"])
}

@Test func enforcesMaximumEntryCount() throws {
    let store = try ClipboardStore.temporary(maxEntries: 2)
    _ = try store.insert(.text("one"))
    _ = try store.insert(.text("two"))
    _ = try store.insert(.text("three"))

    #expect(store.list().map(\.displayText) == ["three", "two"])
}

@Test func persistsImagePayloadAndFiltersText() throws {
    let store = try ClipboardStore.temporary()
    let image = Data([0, 1, 2, 3])
    _ = try store.insert(.image(image))
    _ = try store.insert(.text("Swift clipboard"))

    #expect(store.list(query: "swift").map(\.displayText) == ["Swift clipboard"])
    #expect(store.list().first?.payload == .text("Swift clipboard"))

    let reopened = try ClipboardStore(directory: store.directory)
    #expect(reopened.list().last?.payload == .image(image))
}
