# 固定剪贴板条目（钉住置顶）· 设计文档

日期：2026-10-10
状态：待实现
目标：`ClipboardManagerCore` 加一个状态位，`⌘⇧V` 菜单顶部多出一个固定区。

---

## 1. 目标

用户可以把若干条剪贴板内容钉在历史菜单顶部，作为一个单独的小区块长期可达。钉住的条目：

- 不会被 `trim()` 的 50 条上限淘汰
- 出现在 `⌘⇧V` 分页菜单和「显示历史」滚动菜单的**最顶部**，与近期条目分段
- 用一个 24pt 高的行展示，行尾带图钉按钮

「固定」是条目的一个**状态**，不是另一类条目。这是整份设计的地基：数据层用一列表达它，UI 用一个区块渲染它，其余已有操作（`promote` / `delete` / `clear`）语义不变。

---

## 2. 决策摘要

| 决策 | 结论 |
|---|---|
| 固定区位置 | 同一个 `⌘⇧V` 菜单顶部，与近期条目同屏分段 |
| 是否独占 | **不出现**在近期列表里——固定即移出近期 |
| 上限 | 5 条，未固定的历史**仍然是 50 条**（总行数可达 55） |
| 存储 | `clips` 表加一列 `pinned`，不是新表 |
| 行预算 | 菜单 300 → 348pt（14 行）；近期每页 `min(11, 14 - 1 - 本页固定数)` |
| 菜单宽度 | 260 → 282pt，标题渲染预算维持实测 199pt |
| 图钉位置 | 行尾，删除按钮左侧 6pt；未固定行高亮才出现，已固定行常驻 |
| 图钉字形 | 未固定 `pin`，已固定 `pin.slash`（带斜杠＝取消固定） |
| 序号 | 固定行不参与编号；近期行按近期序号连续编号 |
| 分隔线 | 画在第一条近期行顶部，零垂直成本 |
| 取消固定 | 按原 `created_at` 回到近期列表，**不隐式 promote** |
| 钉满反馈 | 图钉按钮泛红 0.6s，不弹窗、不自动踢掉最老的 |

---

## 3. 数据层（`ClipboardManagerCore`）

### 3.1 Schema 与迁移

`clips` 表新增一列：

```sql
pinned INTEGER NOT NULL DEFAULT 0
```

`ClipboardStore.init` 在现有 `CREATE TABLE IF NOT EXISTS` 之后追加一步探测：

1. 跑 `PRAGMA table_info(clips)`，逐行读第 1 列（`name`）
2. 列名里没有 `pinned` → `ALTER TABLE clips ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0`

新库走 CREATE 直接拿到最终 schema，探测不命中；老库 CREATE 空转（表已存在），ALTER 补列。两条路径收敛到同一张表。

**不**采用「捕获 ALTER 失败再匹配 `duplicate column name: pinned` 错误字符串」——那更省事，但把正确性挂在 SQLite 的英文错误信息上。

这一步是本次改动里唯一「错了不报错、只是用户历史凭空少一半」的路径，因此必须有专门测试（3.5 第 6 条）。

### 3.2 上限是 store 的不变式

与 `maxEntries` 同构：`let`、无 setter、无 UI、不进 `init`。

```swift
/// How many entries may be pinned at once. Fixed rather than adjustable, for the same reason
/// `maxEntries` is: the pinboard is a handful of always-reachable entries, and a board the user
/// can grow without bound stops being one. Enforced by `setPinned`, not by the UI.
public let maxPinnedEntries = 5

public enum PinOutcome: Equatable, Sendable {
    case pinned
    case unpinned
    /// The pinboard is full. Not an error — a refusal the caller is expected to show.
    case refusedBoardIsFull
}

@discardableResult
public func setPinned(_ pinned: Bool, id: UUID) throws -> PinOutcome
```

返回 outcome 而不是抛 `StoreError`：钉满是产品决策（拒绝 + 给反馈），不是 IO 失败。抛异常会把「钉上了」和「钉不上」压进同一个 `catch`，UI 无法只对后者给反馈。

`maxPinnedEntries` 不做 init 参数：`maxEntries` 可注入是因为测试要造出超限历史，而 5 条上限用默认值插 6 次就能测。

`setPinned` 的行为：

- `pinned == true`：若未固定条目数已达上限 → 返回 `.refusedBoardIsFull`，**不写库**
- 其它情况：`UPDATE clips SET pinned = ? WHERE id = ?`，返回对应 outcome
- id 不存在（幽灵调用）：UPDATE 影响 0 行，按上面的分支返回。UI 不会产生这种调用——它总是从 `list()` 拿到的 id

### 3.3 `list()` 与排序

```sql
SELECT id, created_at, kind, payload FROM clips ORDER BY pinned DESC, created_at DESC
```

`ClipRecord` 增加 `isPinned: Bool`，**带默认值 `false`**，现有调用点与测试一个都不用改。

控制器拿一次查询，在内存里切成两段（`records.filter(\.isPinned)` / `filter { !$0.isPinned }`），保证两段来自同一份快照。

`list(query:)` 一并改排序。它没有调用方（见 `todo.md` 搜索一节），保持同步改动即可。

**不新增索引。** 表上限 55 行，`clips_created_at` 现在就已是摆设；`ORDER BY pinned DESC, created_at DESC` 对 55 行全表扫描没有收益。

### 3.4 `trim()` 改写

```sql
DELETE FROM clips WHERE pinned = 0 AND id NOT IN (
  SELECT id FROM clips WHERE pinned = 0 ORDER BY created_at DESC LIMIT 50)
```

语义变为「保留 50 条未固定的 + 全部固定的」。id 由子查询自身产出，不经外部字符串，因此不受 `todo.md` 记的 id 大小写坑影响。

### 3.5 测试清单（`Tests/ClipboardManagerCoreTests`，Swift Testing）

1. `pinnedEntriesSortAheadOfTheRecentOnes` — `list()` 前段是固定项，按 `created_at` 降序
2. `pinningExemptsAnEntryFromTheFiftyEntryCap` — 插满并超出上限，最早那条 pin 之后再 `insert` 触发 `trim()`，它仍在
3. `unpinningReturnsAnEntryToTheRecentCap` — 取消固定后该条目重新进入淘汰序列，在下一次 `insert` 的 `trim()` 中被删除
4. `pinningIsRefusedOnceTheBoardIsFull` — 第 6 次 `setPinned(true, …)` 得到 `.refusedBoardIsFull`，且固定条数仍为 5
5. `thePinFlagSurvivesReopeningTheDatabase` — 关闭重开后 `isPinned` 仍为 `true`
6. `addingThePinColumnToAnExistingDatabaseKeepsItsRows` — **迁移测试**：用裸 `sqlite3` 建一张无 `pinned` 列的旧 schema 表、塞两行，再用 `ClipboardStore` 打开，断言两行都还在且 `isPinned == false`
7. `promotingAPinnedEntryMovesItWithinThePinnedSection` — `promote` 后该固定项排到固定区第一位，总条数不变

---

## 4. UI 层（`ClipboardManagerApp`）

### 4.1 宽度

`maxMenuWidth: 260 → 282`。实测（13pt 菜单字体、`ordinalWidth(50) = 17pt`）：

| 菜单宽 | 标题（今天） | 标题（加图钉按钮后） |
|---|---|---|
| 260pt | 199pt | 177pt |
| **282pt** | 221pt | **199pt ← 维持现状** |

`HistoryRowView.titleWidth` 增加两个参数：

- `showsPinButton` — 固定行与近期行都传 `true`。按钮永远占位，即使未高亮时是隐藏的，否则标题会在高亮那一刻横向跳一下
- `showsOrdinal` — 固定行传 `false`（见 4.4）

### 4.2 高度预算从常量推出

```
maxMenuHeight:            300 → 348pt
menuChromeHeight:         12              // 实测，不动
maxRowsPerPage = (348 - 12) / 24 = 14
recordsPerPage = min(11, maxRowsPerPage - 页脚(1) - 本页固定数)
```

`min(11, …)` 是这条规则的关键：**一条都没固定时菜单与今天逐像素一致（11 条 / 300pt）**，不会因为上限抬到 14 行就凭空多给两行。

| 固定条数 | 第 1 页近期 | 菜单高度 |
|---|---|---|
| 0 | 11 | 300pt |
| 1 | 11 | 324pt |
| 2 | 11 | 348pt |
| 3 | 10 | 348pt |
| 4 | 9 | 348pt |
| 5 | 8 | 348pt |

一句话规则：**固定 ≤2 条时菜单变高、近期一条不减；从第 3 条起才挤。**

滚动模式不分页，`recordsPerPage = Int.max`，同一套两段结构。

### 4.3 分隔线

画在**第一条近期行的顶部**，不是固定区末尾。

理由是边界自动正确：有近期行才画线，所以「固定 5 条 + 近期 0 条」不需要任何特判。

实现：`HistoryRowView` 增加 `drawsDivider: Bool = false`，在 `draw(_:)` 里沿 `bounds` 顶部填 1pt `separatorColor`。与 `HistoryFooterView` 画分隔线同一手法——零垂直成本，不新增 `NSMenuItem`。

### 4.4 固定行不参与编号

`HistoryRowView.ordinal` 改为 `Int?`。`nil`（固定行）时不创建 `ordinalField`，标题从 `padding` 起排。留一列空白看起来像 bug。

副作用：固定行标题预算 = 199 + 17 + 6 = **222pt**，近期行 199pt。这个不对称是有意的——固定的几条本来最该看清。

`ordinalWidth` 改用 `records.count`（未固定条数）度量。

### 4.5 图钉按钮

位置：行尾，删除按钮左侧 6pt，宽 16pt，与删除按钮同一套 reveal 机制（挂在 `isHighlighted` 的 `didSet` 上），不引入 `NSTrackingArea`。

| 行状态 | 可见性 | 字形 | 点击行为 |
|---|---|---|---|
| 未固定，未高亮 | 隐藏 | `pin` | — |
| 未固定，高亮 | 显示 | `pin` | 固定 |
| 已固定（任意高亮状态） | **常驻** | `pin.slash` | 取消固定 |

`pin.slash` 在 macOS 26.5.2 实测存在（`pushpin` / `pushpin.fill` 不存在）。它随 SF Symbols 4.0（macOS 13）引入，覆盖 macOS 14 部署目标，但**只在本机验证过**，因此加一行 `pin.fill` 兜底——一行成本换一个静默空白按钮的不可能。

### 4.6 钉满时的反馈

`setPinned` 返回 `.refusedBoardIsFull` → 图钉按钮 `contentTintColor` 短暂变为 `.systemRed`，`pinRefusalFlashSeconds = 0.6` 秒后复原。**不弹窗、不自动踢掉最老的那条固定、不重建菜单。**

实现约束：泛红标志与 `isHighlighted` 必须共用同一个 `updateTint()`，否则「泛红期间高亮状态变化」会留下一个不红或不复原的按钮。

这是对一次明确点击的拒绝反馈，与 `todo.md` 里原则性否决的「捕获时的视觉反馈」性质不同：后者是高频复制时的环境干扰，前者是低频明确操作后的响应。

### 4.7 分页与高亮

- 固定条目只出现在第 1 页顶部；翻页后固定区与分隔线一并消失
- `pageCount` 只数近期条目：`min(maxPages, ceil(近期数 / recordsPerPage))`
- `visibleRecords` = `固定 + 近期[当前页切片]`，`highlightedRow` 是它的下标——「画的行」和「↵ 提交的行」仍然是同一个来源
- 翻页后 `highlightedRow = 0`：第 1 页落在第一条固定上，第 2/3 页落在第一条近期上
- 菜单打开时高亮第 0 行 = 第一条固定

### 4.8 边界情况

1. **固定 5 条 + 近期 0 条** → 5 行 + 页脚，无分隔线（由 4.3 自动成立）
2. **固定条目被删除** → 固定区缩短，分隔线上移，菜单高度回落
3. **取消固定不隐式 promote**：按原 `created_at` 回到近期列表它本该在的位置。一条放了很久的固定项取消固定后可能已在 50 名之外，下一次 `insert` 的 `trim()` 会淘汰它——这与「取消固定就是让它重新变回临时内容」一致
4. **完全为空**（无固定、无近期）→ 现有的两行空状态文案不变

---

## 5. 明确不做

| 不做 | 理由 |
|---|---|
| 键盘固定快捷键 | `HotkeyTap` 的 `onUnmodifiedKey` 只收无修饰键，← → ↵ 已占。新增全局修饰键通路等于从目标应用手里抢键（⌘P 是打印，⌃P 是命令面板）；且菜单跟踪时自带事件循环，加了也不是唯一路径 |
| 设置项 | 固定上限 5 是 `let`，与 `maxEntries` 同构，没有 UI |
| 状态栏入口 / 第二个快捷键 | 会引出一整套录制、显示名、keyEquivalent 同步逻辑（`applyShortcutToStatusMenu` 那套） |
| 拖拽排序 | 固定区顺序即「最近用过的在前」，`promote()` 已经给出 |
| 清空历史时保留固定 | 「清空历史」的文案是「所有已保存的记录都会被删除」，保留固定与该文案矛盾 |

---

## 6. 错误处理

与 `delete` 同一套，无新增形态：

- `setPinned` 抛错（IO 失败）→ `NSLog` + **不动 UI**，菜单原样继续可用，不弹窗
- 返回 `.refusedBoardIsFull` → 图钉按钮泛红 0.6s，不重建菜单

---

## 7. 验证

`ClipboardManagerApp` 是无测试目标（见 `CLAUDE.md`），数据层 3.5 的七条测试是自动的，交互靠手动：

```bash
swift test --disable-sandbox
swift run --disable-sandbox ClipboardManagerApp
```

**必须用 `open` 启动，不能从终端直接跑**——从终端启动的进程继承终端自己的辅助功能授权，会让未签名的构建谎报 `trusted: 1`。

手动要看的四件事：

1. 一条都没固定时，菜单与改动前逐像素一致（11 条 / 300pt）
2. 固定一条后，它出现在最顶部、分隔线在它下方、序号列消失
3. 钉到第 6 条时按钮泛红而不是静默失败或弹窗
4. 取消固定后该行回到近期列表的原时间位置

---

## 8. 文档同步

实现完成后同步：

- **`CLAUDE.md` 存储章节**：`pinned` 列与 `PRAGMA table_info` 迁移探测、改写后的 `trim()`、`setPinned` 返回 outcome 而非抛错的理由、`maxPinnedEntries` 不进 `init`
- **`CLAUDE.md` UI 章节**：菜单 282×348pt、14 行预算与 `min(11, …)` 规则、固定区与分隔线、图钉按钮的显示规则、`pin.slash` 字形
- **`todo.md` 第三节「已决策不做」**：记一条「固定只走指针，不开设置项和第二入口」，避免日后被重新提出

另：`./scripts/build-app.sh` 会改动 git 跟踪的 `dist/`。重建后必须重新签名，否则本机辅助功能授权在每次重建后失效（见 `CLAUDE.md` 签名一节）。
