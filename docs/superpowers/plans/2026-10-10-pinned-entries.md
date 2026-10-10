# 固定剪贴板条目（钉住置顶）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户把任意剪贴板条目钉在 `⌘⇧V` 历史菜单顶部单独成区，钉住的条目不受 50 条上限淘汰。

**Architecture:** 「固定」是条目的一个状态，不是另一类条目，所以存储层是 `clips` 表加一列 `pinned`，`promote` / `delete` / `clear` 语义全部不变；只有 `trim()` 和 `list()` 的排序需要改。UI 层 `HistoryRowView` 挂一个与删除按钮同一套 reveal 机制的图钉按钮，`HistoryPanelController` 把一次查询切成「固定 + 近期」两段，并从菜单高度常量推导出每页行数。

**Tech Stack:** Swift 6（`swiftLanguageModes: [.v6]`，strict concurrency）、SwiftPM、裸 `import SQLite3` C API、Swift Testing、AppKit（全部手写 UI，无 SwiftUI/XIB）。

**设计文档：** `docs/superpowers/specs/2026-10-10-pinned-entries-design.md`

## Global Constraints

- 所有 SwiftPM 命令必须带 `--disable-sandbox`（SwiftPM 自己的沙箱和本环境的沙箱冲突）。
- 测试用 Swift Testing（`import Testing` + 顶层 `@Test func`），不是 XCTest。
- 全部用户可见文案用简体中文；注释和标识符用英文。
- `maxEntries` 保持 50，且**仍然只约束未固定条目**；`maxPinnedEntries = 5`，是 `let`、无 setter、无 UI、不进 `init`。
- 菜单宽 **282pt**、高 **348pt**；`maxRowsPerPage = (348 - 12) / 24 = 14`；每页近期条数 = `max(1, min(11, maxRowsPerPage - 1 - 固定数))`。
- 标题截断预算：近期行 **199pt**、固定行 **222pt**。
- 图钉按钮 16pt，在删除按钮左侧 6pt；`pinRefusalSeconds: TimeInterval = 0.6`。
- 字号 13pt（`NSFont.menuFont(ofSize: 0)`），`ordinalWidth(50) = 17pt`。
- **`main.swift`（`AppDelegate`）、`SettingsController.swift`、`AutoPaster.swift`、`HotkeyTap.swift`、`ClipboardMonitor.swift` 本次一律不改。**
- 不新增索引、不新增设置项、不新增快捷键、不新增状态栏入口。
- `ClipboardManagerApp` 是无测试目标：UI 改动以 `swift build --disable-sandbox` 为门禁，交互靠手测。

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/ClipboardManagerCore/ClipboardManagerCore.swift` | 修改 | 迁移、`isPinned`、`setPinned`、上限、`trim()`、`list()` 排序 |
| `Tests/ClipboardManagerCoreTests/PinnedEntriesTests.swift` | 新建 | 本特性全部 7 条数据层测试 |
| `Sources/ClipboardManagerApp/HistoryRowViews.swift` | 修改 | 图钉按钮、可选序号列、分隔线、泛红与统一外观 |
| `Sources/ClipboardManagerApp/HistoryPanelController.swift` | 修改 | 两段结构、从常量推导的行预算、翻页与固定区接线 |
| `CLAUDE.md` | 修改 | 存储章节与 UI 层章节 |
| `todo.md` | 修改 | 「已决策不做」记一条边界 |

`HistoryRowViews.swift` 与 `HistoryPanelController.swift` 不拆分：本次分别增加约 60 行和约 80 行，拆开会把「行的排版」和「菜单的排版」割裂在两个文件里。

---

### Task 1: 让 `pinned` 列在旧数据库上也能被读到

**Files:**
- Create: `Tests/ClipboardManagerCoreTests/PinnedEntriesTests.swift`
- Modify: `Sources/ClipboardManagerCore/ClipboardManagerCore.swift`

**Interfaces:**
- Consumes: 现有 `ClipboardStore(directory:)`、`list(query:)`
- Produces: `ClipRecord.isPinned: Bool`（`init` 带 `isPinned: Bool = false` 默认值）、`ClipboardStore.addPinColumnIfMissing()`（private）、`list()` 按 `pinned DESC, created_at DESC` 排序并读出第 5 列
- 本任务**不**引入 `setPinned`——它属于 Task 2。因此本任务的测试文件里只有一条测试。

- [ ] **Step 1: 写迁移测试**

新建 `Tests/ClipboardManagerCoreTests/PinnedEntriesTests.swift`：

```swift
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
```

- [ ] **Step 2: 让 `list()` 依赖 `pinned`，但先不加迁移**

这一步**故意**只改读取侧，不补列。改完测试就会红，红的原因正是线上会发生的那个原因。

**(a) `ClipRecord` 加字段**：

```swift
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
```

默认参数 `false` 保证既有测试与调用点一个都不用改。

**(b) 建表语句追加 `pinned` 列**（放最后，与 `list()` 的 SELECT 顺序一致，也让后面 ALTER 追加的位置一致）：

```swift
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
```

**(c) `list()` 的 SELECT 与排序**：

```swift
    public func list(query: String? = nil) -> [ClipRecord] {
        let sql = query?.isEmpty == false
            ? "SELECT id, created_at, kind, payload, pinned FROM clips WHERE kind = 0 AND lower(CAST(payload AS TEXT)) LIKE lower(?) ORDER BY pinned DESC, created_at DESC"
            : "SELECT id, created_at, kind, payload, pinned FROM clips ORDER BY pinned DESC, created_at DESC"
```

不为此加索引：表上限 50 + 5 = 55 行，`clips_created_at` 现在也已经是摆设。

**(d) `record(from:)` 读第 5 列**：

```swift
        return ClipRecord(id: id, createdAt: date, payload: payload, isPinned: sqlite3_column_int(statement, 4) != 0)
```

- [ ] **Step 3: 跑测试，确认它红**

```
swift test --disable-sandbox --filter addingThePinColumnToAnExistingDatabaseKeepsItsRows
```

预期：FAIL。`list()` 里的 `guard (try? prepare(...))` 在四列的旧表上失败并返回 `[]`，于是 `#expect(store.list().map(\.displayText) == ["kept"])` 得到空数组。

**这个红是本任务存在的理由。** 它证明：只加读取、不加迁移，装过旧版的用户会看到一份空历史，而且没有任何错误提示。

- [ ] **Step 4: 加上迁移**

在 `ClipboardStore` 里，`init` 的 `do { try execute(...) } catch { ... }` 中，`execute` 之后、`} catch {` 之前插入一行：

```swift
            try addPinColumnIfMissing()
```

并在 `trim()` 上方加这个方法：

```swift
    /// Adds the `pinned` column to a database created before pinning existed.
    ///
    /// A fresh database already has it from the `CREATE TABLE` above, so this is a no-op there;
    /// an existing one has it appended, which leaves the physical column order the same either
    /// way. Probing `table_info` rather than catching "duplicate column name" keeps the
    /// correctness off SQLite's English error strings.
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
```

- [ ] **Step 5: 跑全部测试，确认绿**

```
swift test --disable-sandbox
```

预期：既有 7 条 + 新增 1 条全部 PASS。特别确认 `persistsAcrossStoreInstances` 仍然 PASS——它走的是全新目录，`addPinColumnIfMissing` 应当探测到列已存在、直接返回。

- [ ] **Step 6: 提交**

```bash
git add Sources/ClipboardManagerCore/ClipboardManagerCore.swift Tests/ClipboardManagerCoreTests/PinnedEntriesTests.swift
git commit -m "feat: add a pin column to the clip table

A pinned entry is the same kind of entry with a state on it, so the
column goes on clips rather than into a second table. CREATE TABLE IF
NOT EXISTS leaves an installed database untouched, so the column is
probed for and added — without it, reading pinned against a real user's
four-column table fails the prepare, and list() answers an empty history
instead of an error."
```

---

### Task 2: `setPinned`、上限与 `trim()` 改写

**Files:**
- Modify: `Sources/ClipboardManagerCore/ClipboardManagerCore.swift`
- Modify: `Tests/ClipboardManagerCoreTests/PinnedEntriesTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `ClipRecord.isPinned`、`addPinColumnIfMissing()`
- Produces: `ClipboardStore.maxPinnedEntries: Int`、`PinOutcome`（`.pinned` / `.unpinned` / `.refusedBoardIsFull`，`Equatable` + `Sendable`）、`ClipboardStore.setPinned(_:id:) throws -> PinOutcome`（`@discardableResult`）；`trim()` 保留 50 条未固定 + 全部固定

- [ ] **Step 1: 写六条失败的测试**

追加到 `Tests/ClipboardManagerCoreTests/PinnedEntriesTests.swift`：

```swift
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
    #expect(store.list().map(\.displayText) == ["second", "oldest"])

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
```

- [ ] **Step 2: 跑测试，确认它红**

```
swift test --disable-sandbox --filter PinnedEntriesTests
```

预期：编译失败，报 `value of type 'ClipboardStore' has no member 'setPinned'`。

- [ ] **Step 3: 实现上限常量与 `PinOutcome`**

在 `ClipboardStore` 里紧跟 `maxEntries` 声明之后：

```swift
    /// How many entries may be pinned at once. Fixed rather than adjustable for the same reason
    /// `maxEntries` is: the pinboard is the handful of entries always worth reaching, and a board
    /// that grows without bound stops being one. Enforced here rather than in the UI so that it
    /// is a property of the store and can be tested.
    public let maxPinnedEntries: Int = 5
```

`StoreError` 上方、`ClipboardStore` 下方：

```swift
/// What `setPinned` did. A full pinboard is a refusal rather than a failure, because the caller is
/// expected to show it and carry on — throwing would collapse "pinned" and "could not pin" into
/// one `catch`, and the UI could then no longer tell the user which happened.
public enum PinOutcome: Equatable, Sendable {
    case pinned
    case unpinned
    case refusedBoardIsFull
}
```

- [ ] **Step 4: 实现 `setPinned` 与计数**

在 `delete(id:)` 之前插入：

```swift
    /// Pins or unpins an entry, exempting it from the entry cap while it is pinned.
    ///
    /// Refuses rather than throwing when the board is full, and never drops an existing pin to
    /// make room: which entry loses its place is the user's decision, not a side effect of
    /// pinning something else.
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
```

`maxPinnedEntries` 不进 `init`：`maxEntries` 可注入是因为测试要造出超限历史，而 5 条上限插 6 次就够测。

- [ ] **Step 5: 改写 `trim()`**

```swift
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
```

- [ ] **Step 6: 跑全部测试，确认绿**

```
swift test --disable-sandbox
```

预期：14 条全部 PASS（既有 7 + 新增 7）。特别确认 `enforcesMaximumEntryCount` 仍然 PASS——它一条都没 pin，新 WHERE 子句对它应当是空操作。

- [ ] **Step 7: 提交**

```bash
git add Sources/ClipboardManagerCore/ClipboardManagerCore.swift Tests/ClipboardManagerCoreTests/PinnedEntriesTests.swift
git commit -m "feat: exempt pinned entries from the entry cap

trim() now counts recent entries only, so pinning costs the user nothing
they did not ask to give up. A full pinboard refuses rather than throwing,
and refuses rather than dropping the oldest pin."
```

---

### Task 3: 行视图的图钉按钮、可选序号列与分隔线

**Files:**
- Modify: `Sources/ClipboardManagerApp/HistoryRowViews.swift`

**Interfaces:**
- Consumes: 无（不引用 Task 1/2 的符号；调用方在 Task 4 接线）
- Produces: `HistoryRowView.pinRefusalSeconds: TimeInterval`、`HistoryRowView.titleWidth(hasThumbnail:showsOrdinal:ordinalWidth:totalWidth:)`、`HistoryRowView.init(title:thumbnail:ordinal:isPinned:ordinalWidth:totalWidth:)`、`HistoryRowView.drawsDivider: Bool`、`HistoryRowView.refusePin()`、`HistoryRowView.onTogglePin: (() -> Void)?`
- 本任务结束时 `HistoryPanelController` 尚未适配新签名，`swift build` **会失败**——这是预期的，Step 6 确认失败原因只有签名不匹配。

- [ ] **Step 1: 改常量与静态方法**

常量块改为：

```swift
    static let height: CGFloat = 24
    private static let padding: CGFloat = 8
    private static let gap: CGFloat = 6
    private static let deleteSize: CGFloat = 16
    private static let pinSize: CGFloat = 16
    private static let thumbnailSize: CGFloat = 18
    private static let cornerRadius: CGFloat = 4

    /// How long the pin button stays red when the pinboard is full: long enough to be seen, short
    /// enough that a red button cannot be mistaken for a state the row is stuck in.
    static let pinRefusalSeconds: TimeInterval = 0.6
```

`titleWidth` 改为：

```swift
    /// Space left for the title once the ordinal, the thumbnail, the two trailing buttons and the
    /// margins are taken. The controller truncates to this before handing text over, because a
    /// label clips rather than ellipsizing.
    ///
    /// Both trailing buttons are reserved whether or not they are on screen. A hidden button that
    /// took no room would let the title widen the moment the row was highlighted, which reads as
    /// the text jumping sideways under the pointer.
    ///
    /// At `totalWidth` 282 with a 17pt ordinal column this is 199pt for a recent row and 222pt for
    /// a pinned one. It was 199pt before the pin button existed, which is why the menu is 282
    /// rather than 260: at 260 it would be 177pt.
    static func titleWidth(hasThumbnail: Bool, showsOrdinal: Bool, ordinalWidth: CGFloat, totalWidth: CGFloat) -> CGFloat {
        var leading = padding
        if showsOrdinal { leading += ordinalWidth + gap }
        if hasThumbnail { leading += thumbnailSize + gap }
        // padding, pin button, its gap, delete button, and the gap between the delete button and
        // the title — five terms, two of them gaps.
        let trailing = padding + pinSize + gap + deleteSize + gap
        return totalWidth - leading - trailing
    }
```

验算：近期行 `282 - (8 + 17 + 6) - (8 + 16 + 6 + 16 + 6) = 282 - 31 - 52 = 199`；固定行 `282 - 8 - 52 = 222`。

- [ ] **Step 2: 改属性、状态与外观入口**

属性块替换为：

```swift
    /// Nil for a pinned row: see `isPinned`. A missing column rather than a blank one, because a
    /// blank column reads as a rendering fault instead of "this one is not counted".
    private let ordinalField: NSTextField?
    private let titleField = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    /// Whether this entry is pinned. A pinned row keeps its pin button on screen at all times —
    /// that constant mark is the whole of how the row says it is pinned — and shows it as the
    /// undo glyph, because clicking it is what unpins.
    private let isPinned: Bool

    var onSelect: (() -> Void)?
    var onDelete: (() -> Void)?
    var onTogglePin: (() -> Void)?

    /// Paints the hairline that ends the pinned section.
    ///
    /// Set on the first recent row rather than on the last pinned one, so the boundary needs no
    /// special case: with nothing recent there is no row to carry it and no line is drawn. Drawn
    /// rather than made an `NSMenuItem.separator()`, which is an item with a height of its own,
    /// and the row budget here is exact.
    var drawsDivider = false {
        didSet { needsDisplay = true }
    }

    private var isRefusingPin = false
```

`isHighlighted` 的 `didSet` 与 tint 逻辑合并到一处：

```swift
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            updateAppearance()
        }
    }

    /// The one place that decides what is visible and what colour everything is.
    ///
    /// The pin button has three states — hidden, shown, refusing — and the refusal has to survive
    /// a highlight change landing on top of it, so the two go through the same entry point rather
    /// than each maintaining their own copy of "what colour is everything".
    private func updateAppearance() {
        pinButton.isHidden = !(isHighlighted || isPinned)
        deleteButton.isHidden = !isHighlighted

        let trailing: NSColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        // A refusal outranks the highlight tint, or it would not read as a refusal at all.
        pinButton.contentTintColor = isRefusingPin ? .systemRed : trailing
        deleteButton.contentTintColor = trailing
        titleField.textColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        ordinalField?.textColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        needsDisplay = true
    }

    /// Answers a refused pin: the board is full, so this click changed nothing.
    ///
    /// Red for a moment rather than an alert. Pinning is a deliberate, infrequent click, so it
    /// deserves an answer, and the thing being reported — one board of five being full — is
    /// smaller than the window an alert would put on screen to say it.
    func refusePin() {
        isRefusingPin = true
        updateAppearance()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.pinRefusalSeconds * 1000)))
            guard let self, self.isRefusingPin else { return }
            self.isRefusingPin = false
            self.updateAppearance()
        }
    }
```

`Task.sleep(for:)` 需要 macOS 13+，与本包的 macOS 14 部署目标相符。毫秒数由 `pinRefusalSeconds` 推出，不另立一个真相源。

- [ ] **Step 3: 改 `init` 的签名与布局**

整个 `init` 替换为下面这一版。注意**先算完再赋属性最后才 `addSubview`**：Swift 不允许在所有存储属性初始化完之前调用 `self` 的方法，而 `ordinalField` 是可选的、分两支赋值。

```swift
    init(title: String, thumbnail: NSImage?, ordinal: Int?, isPinned: Bool, ordinalWidth: CGFloat, totalWidth: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: totalWidth, height: Self.height))
        self.isPinned = isPinned

        var titleOriginX = Self.padding
        let ordinalLabel: NSTextField?
        if let ordinal {
            let label = NSTextField(labelWithString: "\(ordinal)")
            label.font = Self.ordinalFont
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.frame = NSRect(x: Self.padding, y: (Self.height - 16) / 2, width: ordinalWidth, height: 16)
            ordinalLabel = label
            titleOriginX = label.frame.maxX + Self.gap
        } else {
            ordinalLabel = nil
        }
        ordinalField = ordinalLabel
        if let ordinalLabel { addSubview(ordinalLabel) }

        if let thumbnail {
            thumbnailView.image = thumbnail
            thumbnailView.imageScaling = .scaleProportionallyUpOrDown
            thumbnailView.frame = NSRect(
                x: titleOriginX,
                y: (Self.height - Self.thumbnailSize) / 2,
                width: Self.thumbnailSize,
                height: Self.thumbnailSize
            )
            addSubview(thumbnailView)
            titleOriginX = thumbnailView.frame.maxX + Self.gap
        }

        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "删除")
        deleteButton.imagePosition = .imageOnly
        deleteButton.isBordered = false
        deleteButton.bezelStyle = .inline
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.frame = NSRect(
            x: totalWidth - Self.padding - Self.deleteSize,
            y: (Self.height - Self.deleteSize) / 2,
            width: Self.deleteSize,
            height: Self.deleteSize
        )
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isHidden = true
        addSubview(deleteButton)

        // `pin.slash` is the undo glyph — a pin with a slash through it — and it ships with
        // SF Symbols 4.0, so the macOS 14 deployment target has it. The fallback is there
        // because `NSImage(systemSymbolName:)` answers a symbol it cannot find with nil, and a
        // button with no image is a blank the size of a target rather than an error.
        let pinSymbol = isPinned ? "pin.slash" : "pin"
        let pinFallback = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: pinSymbol, accessibilityDescription: isPinned ? "取消固定" : "固定")
            ?? NSImage(systemSymbolName: pinFallback, accessibilityDescription: nil)
        pinButton.imagePosition = .imageOnly
        pinButton.isBordered = false
        pinButton.bezelStyle = .inline
        pinButton.contentTintColor = .secondaryLabelColor
        pinButton.frame = NSRect(
            x: deleteButton.frame.minX - Self.gap - Self.pinSize,
            y: (Self.height - Self.pinSize) / 2,
            width: Self.pinSize,
            height: Self.pinSize
        )
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.isHidden = !isPinned
        addSubview(pinButton)

        titleField.stringValue = title
        titleField.font = .menuFont(ofSize: 0)
        titleField.lineBreakMode = .byClipping
        titleField.frame = NSRect(
            x: titleOriginX,
            y: (Self.height - 16) / 2,
            width: pinButton.frame.minX - Self.gap - titleOriginX,
            height: 16
        )
        addSubview(titleField)
    }
```

`init` 上方的文档注释补一句：

```swift
    /// `ordinal` is the entry's position in the recent sequence; pass `nil` for a pinned entry,
    /// which has left that sequence and therefore has no position in it.
```

- [ ] **Step 4: 改 `draw` 并新增 action**

```swift
    override func draw(_ dirtyRect: NSRect) {
        // Under the highlight, not over it: a hairline in separator colour drawn across the
        // selection fill would read as a grey line through the selected row.
        if drawsDivider {
            NSColor.separatorColor.setFill()
            NSRect(x: Self.padding, y: bounds.height - 1, width: bounds.width - Self.padding * 2, height: 1).fill()
        }
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
```

在 `deleteTapped` 之后加：

```swift
    @objc private func pinTapped() {
        onTogglePin?()
    }
```

- [ ] **Step 5: 确认 `HistoryFooterView` 一字未动**

`HistoryFooterView` 自己画分隔线、自己有 `onPrevious` / `onNext`，与固定区无交集，不改。

- [ ] **Step 6: 构建，确认失败原因只有签名不匹配**

```
swift build --disable-sandbox
```

预期：报错全部指向 `HistoryPanelController` 里的两处调用——`HistoryRowView(...)`（`ordinal` 由 `Int` 变 `Int?`、新增 `isPinned` 参数）和 `HistoryRowView.titleWidth(...)`（新增 `showsOrdinal` 参数）。**若报的是别的错，先修本任务的文件**，不要往下走。

- [ ] **Step 7: 提交**

```bash
git add Sources/ClipboardManagerApp/HistoryRowViews.swift
git commit -m "feat: give history rows a pin button, an optional ordinal and a divider

The pin button rides the same reveal as the delete button rather than a
tracking area, which a tracking menu does not deliver reliably, and a
pinned row keeps it on screen because that constant mark is the state.
The hairline rides the first recent row rather than the last pinned one,
so a pinboard with nothing recent under it needs no special case."
```

---

### Task 4: 控制器把菜单切成固定区与近期区

**Files:**
- Modify: `Sources/ClipboardManagerApp/HistoryPanelController.swift`

**Interfaces:**
- Consumes: Task 2 的 `setPinned(_:id:) -> PinOutcome`、`PinOutcome`；Task 3 的 `HistoryRowView.init(title:thumbnail:ordinal:isPinned:ordinalWidth:totalWidth:)`、`titleWidth(hasThumbnail:showsOrdinal:ordinalWidth:totalWidth:)`、`drawsDivider`、`refusePin()`、`onTogglePin`
- Produces: 无（UI 终点）

- [ ] **Step 1: 改常量**

```swift
    /// Widest the menu may render. 282 rather than 260 because the pin button takes 22pt out of
    /// the row: at 260 the title would shrink to 177pt, and at 282 it keeps the 199pt it has
    /// always had, so a board of zero pins truncates exactly as it did before pinning existed.
    private let maxMenuWidth: CGFloat = 282
    /// Tallest the menu may render. 348pt is fourteen 24pt rows, which is what a full pinboard
    /// above a full first page adds up to.
    private let maxMenuHeight: CGFloat = 348
    /// Vertical space the menu spends on padding, measured from a rendered menu.
    private let menuChromeHeight: CGFloat = 12
    /// Rows the height cap buys once the chrome is subtracted. Stated rather than divided at each
    /// use so that raising the cap cannot leave the budget and the per-page count disagreeing.
    private var maxRowsPerPage: Int {
        Int((maxMenuHeight - menuChromeHeight) / HistoryRowView.height)
    }
    /// Ceiling on pages, so a long history cannot turn the pop-up into an endless pager. Entries
    /// past the last page stay reachable through `Mode.scrolling`.
    private let maxPages = 3
```

删除原来的 `private let recordsPerPage = 11`——它变成 Step 3 的计算属性。

- [ ] **Step 2: 替换记录状态与加载**

属性与 `init` 替换为：

```swift
    private let store: ClipboardStore
    /// The two sections, refreshed together from a single `list()` call so they can never
    /// disagree about what the history holds.
    private var pinnedRecords: [ClipRecord] = []
    private var recentRecords: [ClipRecord] = []
    private var pendingSelection: ClipRecord?
    private var mode: Mode = .paged
    private var page = 0
    private var activeMenu: NSMenu?
    /// Which row of the current page carries the highlight. See the note on
    /// `menu(_:willHighlight:)` for why this is held here rather than read back from the menu.
    private var highlightedRow = 0

    init(store: ClipboardStore) {
        self.store = store
    }

    /// Re-reads the whole history and splits it into the two sections the menu draws.
    private func loadRecords() {
        let stored = store.list()
        pinnedRecords = stored.filter(\.isPinned)
        recentRecords = stored.filter { !$0.isPinned }
    }
```

- [ ] **Step 3: 替换分页、行预算与 `visibleRecords` 这一组**

把 `pageCount`、`currentPage`、`visibleStart`、`visibleRecords`、`ordinalWidth` 五个计算属性整体替换为下面这组：

```swift
    private var pageCount: Int {
        min(maxPages, max(1, (recentRecords.count + recordsPerPage - 1) / recordsPerPage))
    }

    /// Clamped, because deleting entries can leave the stored page past the last one.
    private var currentPage: Int {
        min(page, pageCount - 1)
    }

    /// How many recent rows a page carries.
    ///
    /// The pinboard is drawn above them on page one and is not repeated on later pages, so the
    /// budget it costs is paid once. Up to two pins the recent rows still fit and the menu simply
    /// grows; from the third they have to give. `min(11, …)` is what makes a board of zero pins
    /// byte-identical to the menu that shipped before pinning — without it, raising the cap to
    /// fourteen rows would silently hand every user two extra entries per page.
    private var recordsPerPage: Int {
        guard mode == .paged else { return max(1, recentRecords.count) }
        return max(1, min(11, maxRowsPerPage - 1 - pinnedRecords.count))
    }

    /// Where the page's first recent row sits in the recent sequence, which is what the rows are
    /// numbered from. Page two starts at 12, not at 1: the number is the entry's position in the
    /// history, and a number that restarted would say nothing the user could not count.
    private var visibleStart: Int {
        mode == .scrolling ? 0 : currentPage * recordsPerPage
    }

    /// The pinboard, which belongs to the first page only — from page two on, the menu is the
    /// recent sequence and nothing else.
    private var visiblePinned: [ClipRecord] {
        mode == .paged && currentPage == 0 ? pinnedRecords : []
    }

    private var visibleRecentEntries: [ClipRecord] {
        let start = visibleStart
        guard start < recentRecords.count else { return [] }
        let end = mode == .scrolling ? recentRecords.count : min(start + recordsPerPage, recentRecords.count)
        return Array(recentRecords[start..<end])
    }

    /// The single list both the menu's rows and `highlightedRow` are derived from, so the row that
    /// is painted and the row Return commits cannot drift apart. A pinned row comes first.
    private var visibleRecords: [ClipRecord] {
        visiblePinned + visibleRecentEntries
    }

    /// Width of the ordinal column, measured against the longest ordinal the menu can show rather
    /// than the one this page happens to end on, so the column does not resize when the page turns.
    /// Measured against the recent count, because pinned rows carry no number.
    private var ordinalWidth: CGFloat {
        HistoryRowView.ordinalWidth(forLargest: max(recentRecords.count, 1))
    }
```

`recordsPerPage` 不依赖 `currentPage`，所以 `pageCount → currentPage → recordsPerPage` 没有循环。

- [ ] **Step 4: 改 `show` 与 `rebuild`**

`show(_:)` 里把 `records = store.list()` 换成 `loadRecords()`。

`rebuild(_:)` 的空状态判断与行循环替换为：

```swift
        guard !pinnedRecords.isEmpty || !recentRecords.isEmpty else {
```

```swift
        // Both modes put the same two sections in the menu; only the footer is paged-only. Which
        // records those are is `visibleRecords`' decision, and it is the same list
        // `highlightedRow` indexes.
        let pinned = visiblePinned
        for (offset, record) in visibleRecords.enumerated() {
            menu.addItem(makeItem(
                for: record,
                ordinal: ordinal(for: record, at: offset),
                // The hairline rides the first recent row rather than the last pinned one, so a
                // pinboard with nothing recent under it draws no line without a special case.
                drawsDivider: offset == pinned.count && !pinned.isEmpty
            ))
        }
```

紧接着在 `rebuild` 之后加：

```swift
    /// The row's number in the recent sequence. A pinned entry has none: the number is a position
    /// among the recent entries, and pinning is precisely having left that sequence.
    private func ordinal(for record: ClipRecord, at offset: Int) -> Int? {
        guard !record.isPinned else { return nil }
        return visibleStart + (offset - visiblePinned.count) + 1
    }
```

- [ ] **Step 5: 改 `makeItem` 与 `title`**

```swift
    private func makeItem(for record: ClipRecord, ordinal: Int?, drawsDivider: Bool) -> NSMenuItem {
        let thumbnail: NSImage?
        if case .image(let data) = record.payload {
            thumbnail = NSImage(data: data)
        } else {
            thumbnail = nil
        }

        let row = HistoryRowView(
            title: title(for: record, ordinal: ordinal),
            thumbnail: thumbnail,
            ordinal: ordinal,
            isPinned: record.isPinned,
            ordinalWidth: ordinalWidth,
            totalWidth: maxMenuWidth
        )
        row.drawsDivider = drawsDivider
        row.onSelect = { [weak self] in
            guard let self else { return }
            self.pendingSelection = record
            self.activeMenu?.cancelTracking()
        }
        row.onDelete = { [weak self] in self?.delete(record) }
        row.onTogglePin = { [weak self] in self?.togglePin(record) }

        let item = NSMenuItem(title: title(for: record, ordinal: ordinal), action: nil, keyEquivalent: "")
        item.view = row
        item.representedObject = record.id.uuidString
        return item
    }
```

```swift
    private func title(for record: ClipRecord, ordinal: Int?) -> String {
        let raw: String
        let hasThumbnail: Bool
        switch record.payload {
        case .text(let value):
            raw = value.replacingOccurrences(of: "\n", with: " ")
            hasThumbnail = false
        case .image(let data):
            raw = "图片 · \(data.count / 1024) KB"
            hasThumbnail = true
        }
        let budget = HistoryRowView.titleWidth(
            hasThumbnail: hasThumbnail,
            showsOrdinal: ordinal != nil,
            ordinalWidth: ordinalWidth,
            totalWidth: maxMenuWidth
        )
        return truncated(String(raw.prefix(maxMeasuredCharacters)), to: budget)
    }
```

- [ ] **Step 6: 改 `delete` 并新增 `togglePin` 与 `rowView`**

```swift
    /// Removes one entry and redraws the rows.
    ///
    /// No confirmation: the click on the row's own delete button is the intent, and the blast
    /// radius is a single row.
    private func delete(_ record: ClipRecord) {
        do {
            try store.delete(id: record.id)
        } catch {
            NSLog("Clipboard history delete failed: %@", String(describing: error))
            return
        }
        loadRecords()
        if let activeMenu { rebuild(activeMenu) }
    }

    /// Pins or unpins an entry, then redraws.
    ///
    /// A full pinboard is answered by the row flashing its own pin button red. Not an alert, and
    /// not dropping the oldest pinned entry to make room: which entry gives up its place is the
    /// user's decision, not a side effect of this click.
    private func togglePin(_ record: ClipRecord) {
        let outcome: PinOutcome
        do {
            outcome = try store.setPinned(!record.isPinned, id: record.id)
        } catch {
            // An I/O failure leaves the menu exactly as it was, which is also the state a user who
            // saw nothing happen can retry from.
            NSLog("Clipboard history pin failed: %@", String(describing: error))
            return
        }
        if outcome == .refusedBoardIsFull {
            rowView(for: record.id, in: activeMenu)?.refusePin()
            return
        }
        loadRecords()
        if let activeMenu { rebuild(activeMenu) }
    }

    /// Finds a row by the id `makeItem` tagged it with.
    ///
    /// `representedObject` is the right source here even though it is the wrong one for the
    /// highlight: this is an identity written here and read back unchanged, with no second copy of
    /// it anywhere for the menu to report instead.
    private func rowView(for id: UUID, in menu: NSMenu?) -> HistoryRowView? {
        menu?.items.first { $0.representedObject as? String == id.uuidString }?.view as? HistoryRowView
    }
```

- [ ] **Step 7: 构建并跑测试**

```
swift build --disable-sandbox && swift test --disable-sandbox
```

预期：两者都通过。

- [ ] **Step 8: 提交**

```bash
git add Sources/ClipboardManagerApp/HistoryPanelController.swift
git commit -m "feat: show the pinboard above the recent entries

The per-page row count is derived from the height cap and the size of the
pinboard instead of being stated, and pinned rows carry no ordinal because
the number is a position among the recent entries."
```

---

### Task 5: 手动验证与文档同步

**Files:**
- Modify: `CLAUDE.md`
- Modify: `todo.md`

**Interfaces:**
- Consumes: Task 1–4 的全部产物
- Produces: 无（代码终点）

- [ ] **Step 1: 手测五件事**

```
swift build --disable-sandbox
./scripts/build-app.sh
open "dist/Clipboard Manager.app"
```

**必须通过 `open` 启动，不能从终端 `swift run`。** 从终端启动的进程继承终端自己的辅助功能授权，未签名的构建会谎报 `trusted: 1`，看起来一切正常。

逐条确认：

1. **一条都没固定时**：`⌘⇧V` 是 11 条 + 页脚，菜单宽 282pt、高 300pt，标题截断与改动前一致。这是最重要的一条——它验证了 `min(11, …)` 与 282pt 的换算都对。
2. **高亮任意一行**：行尾出现「图钉 + 删除」两个按钮，标题不横向跳动。
3. **点图钉**：该行移到最顶部，序号列消失，常驻一个 `pin.slash` 图标；分隔线画在它下方第一条近期行的顶部；菜单变高。
4. **钉到第 6 条**：图钉按钮泛红约 0.6s 后复原，不弹窗、不踢掉最老的那条。
5. **固定 5 条后翻到第 2 页**：固定区和分隔线都不在，近期仍是 8 条一页。

任一条不符，先改代码，不要写文档。

- [ ] **Step 2: 同步 `CLAUDE.md` 存储章节**

在「### Storage」里 `maxEntries` 那段之后插入，并改写现有对 `trim()` 的描述：

```markdown
`maxPinnedEntries` 是 **固定 5** 条，同样是 `let`、无 setter、无 UI，由 `setPinned(_:id:)` 强制执行而不是由界面判断——它是 store 的不变式，所以能被测试。它在 `clips` 表里对应一列 `pinned`，**不加进 `init`**（`maxEntries` 可注入是因为测试要造出超限历史，5 条上限插 6 次就够测）。

`setPinned(_:id:)` 返回 `PinOutcome`（`.pinned` / `.unpinned` / `.refusedBoardIsFull`）而不是抛错：钉满是产品决策（拒绝 + 给反馈），抛 `StoreError` 会把「钉上了」和「钉不上」压进同一个 `catch`，界面就无法只对后者泛红。它也**不踢掉最老的一条固定**来腾位子——哪一条让位是用户的决定。

`pinned` 这列需要迁移。`CREATE TABLE IF NOT EXISTS` 对已存在的表完全不做任何事，所以一个已安装的库仍然是四列的形状，而 `list()` 遇到 prepare 失败会返回 `[]` 而不是报错——补列前它读的是一份**空历史**。做法是 `PRAGMA table_info(clips)` 探测后 `ALTER TABLE ... ADD COLUMN`，而不是捕获 `duplicate column name` 再匹配 SQLite 的英文错误串。

`trim()` 改为 **保留 50 条未固定的 + 全部固定的**。上限只数未固定条目：固定是一次「把它留过时效」的决定，让这个决定反过来缩短近期列表，等于让用户为没钉的东西付出代价。

`list()` 按 `ORDER BY pinned DESC, created_at DESC` 返回，一次查询里固定区在前，控制器自己切成两段，因此两段永远来自同一份快照。不为此加索引：表上限 55 行，`clips_created_at` 现在也已经是摆设。
```

- [ ] **Step 3: 同步 `CLAUDE.md` UI 层章节**

在「### UI layer」里紧跟现有菜单尺寸那段之后插入：

```markdown
菜单尺寸是 **282×348pt**。宽度的 22pt 是留给图钉按钮的：282pt 下近期行的标题仍然是实测的
199pt，260pt 下会掉到 177pt。高度 348pt 是 14 行。

每页的近期条数**从常量推出来**，不是写死的 `recordsPerPage`：
`max(1, min(11, 14 - 页脚1 - 固定数))`。那个 `min(11, …)` 是关键——固定 ≤2 条时菜单只是变高、
近期一条不减，从第 3 条起才开始挤；而一条都没固定时菜单和加这个功能之前逐像素一致，不会因为
上限抬到 14 行就凭空多给两行。固定区只出现在第 1 页，`pageCount` 只数近期条目。

固定行**不参与编号**：序号是条目在近期序列里的位置，而固定正是离开了这个序列。留一个空列看起来
像渲染故障，不如没有。副作用是固定行的标题预算 222pt（`showsOrdinal: false` 多出 17 + 6）。

分隔线画在**第一条近期行的顶部**，不是固定区末尾——有近期行才画线，所以「固定 5 条 + 近期 0 条」
不需要任何特判。画在 `HistoryRowView` 上而不是做成 `NSMenuItem.separator()`，理由和页脚那条线
一样：separator 自己占一行的高度，而这里的行预算是精确的。

图钉按钮挂在与删除按钮同一套 reveal 机制上（`isHighlighted` 的 `didSet` → `updateAppearance()`），
**不引入 `NSTrackingArea`**——测量过的那个坑照旧适用。未固定的行图钉高亮才出现；**已固定的行常驻**，
且常驻的是 `pin.slash`（带斜杠＝取消固定），因为那个常驻标记就是「这条被钉住了」的全部说明，点它
就是取消。

图钉有「隐藏 / 显现 / 拒绝」三态，拒绝那一态与 `isHighlighted` 必须共用 `updateAppearance()`，否则
泛红期间高亮状态一变就会留下一个不红或不复原的按钮。拒绝的表现是泛红 0.6s（`pinRefusalSeconds`），
不是弹窗，也不是自动踢掉最老的一条。
```

- [ ] **Step 4: 在 `todo.md` 第三节记一条不做的**

在「## 三、已决策不做（2026-09-12 界面评审）」的条目末尾追加：

```markdown
### 固定功能只走指针

- 固定在 2026-10-10 落地时，**不做**：键盘固定快捷键、设置项、状态栏第二个入口、拖拽排序、
  「清空历史时保留固定」。
- 键盘不做是因为 `HotkeyTap` 的 `onUnmodifiedKey` 只收无修饰键（← → ↵ 已占），新增全局修饰键
  等于从目标应用手里抢键（⌘P 是打印，⌃P 在一堆编辑器里是命令面板）；其余几项要么引出一整套录制
  与 keyEquivalent 同步逻辑，要么与「清空历史」的文案矛盾。
```

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "docs: record how the pinboard is laid out and what it deliberately leaves out"
```

`dist/` 是 git 跟踪的构建产物，`build-app.sh` 会改动它。脚本默认用 `Apple Development: woden0415@gmail.com (T942J42MF7)` 证书签名，**必须保留**——换成 ad-hoc 会让每次重建都丢掉本机的辅助功能授权：TCC 在授权建立时写入 designated requirement 且此后不再重新生成，ad-hoc 签名没有 Team ID，那个 requirement 退化成一个 cdhash。

- [ ] **Step 6: 收尾自查**

```
swift test --disable-sandbox && git status --short
```

预期：测试全绿；`git status` 为空。
