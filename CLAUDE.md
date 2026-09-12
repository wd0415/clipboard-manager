# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Start here

**Read `todo.md` at the start of every session, before proposing or starting work.** It is the
backlog: what is still outstanding, and for each entry the part of the current implementation it
collides with. It is a list of what is *not* done, not a spec — nothing in it is decided, and a
task that is not in it is new rather than covered by it. Keep it current: when an entry is
finished, delete it there instead of leaving it to rot.

## Commands

All SwiftPM commands need `--disable-sandbox`; SwiftPM's own sandboxing conflicts with the sandboxed shell used here.

```bash
swift build --disable-sandbox                  # build
swift test --disable-sandbox                   # run all tests (Swift Testing, not XCTest)
swift test --disable-sandbox --filter storesTextAndReturnsNewestFirst   # single test

swift run --disable-sandbox ClipboardManagerApp   # run the menu bar app from source

./scripts/build-app.sh                         # build release + bundle dist/Clipboard Manager.app
open "dist/Clipboard Manager.app"
```

`build-app.sh` hardcodes the `.build/arm64-apple-macosx/release/` path, so it only works on Apple Silicon.

The script signs with a certificate — `Apple Development: woden0415@gmail.com (T942J42MF7)` by
default, overridable through `CODESIGN_IDENTITY`, and `-` to go back to ad-hoc. The certificate is
what makes the grant survive a rebuild, so it is worth understanding why ad-hoc cannot.

An ad-hoc signature carries no Team ID, which collapses the designated requirement to a bare
cdhash:

```
# designated => cdhash H"17d331d3a3ecff88d9f972cbba0df784b710c605"
```

TCC stores that requirement when the grant is created and **never regenerates it** — flipping the
switch in System Settings only writes the `auth_value` column. So an ad-hoc build loses the grant
on every rebuild, and no amount of toggling brings it back; the row has to be deleted and re-added
(or `tccutil reset Accessibility local.clipboardmanager.app`) so that a fresh requirement is
derived from the binary that is actually installed. The symptom is "the permission is granted but
the shortcut does nothing" — System Settings still shows that row as ON, because it belongs to the
previous build. Do not conclude the grant is fine from System Settings alone.

The request is logged, and it is the honest readout. A mismatch shows up as:

```
tccd  Failed to match existing code requirement for subject local.clipboardmanager.app
      and service kTCCServiceAccessibility
```

```bash
/usr/bin/log show --last 3m --predicate 'process == "tccd"' --style compact | grep -i clipboard
```

With the certificate the requirement is identity-based instead —

```
designated => identifier "local.clipboardmanager.app" and anchor apple generic and
              certificate leaf[subject.CN] = "Apple Development: woden0415@gmail.com (T942J42MF7)" …
```

— which is the same string after every rebuild, so the grant is given once. `codesign -dvvv` tells
the two apart: ad-hoc prints `Signature=adhoc` and `TeamIdentifier=not set`, the certificate
prints `Authority=` lines and a Team ID. Because the requirement *shape* changes with the signing
mode, switching between the two invalidates the existing grant one last time.

Beware the related measurement trap: an app launched from a terminal **inherits the terminal's own
Accessibility grant**, so an untrusted build reports `trusted: 1` and behaves as if permission were
settled. Launch through `open` to observe the app's real TCC state.

## Architecture

Two targets with a deliberate split, both under one package (`swift-tools-version: 6.3`, `swiftLanguageModes: [.v6]`, macOS 14+, strict concurrency):

- **`ClipboardManagerCore`** (library) — storage and clipboard capture. Everything except the block at the bottom of `ClipboardMonitor.swift` is AppKit-free and platform-agnostic; that block is wrapped in `#if os(macOS)`. This is the only target with tests.
- **`ClipboardManagerApp`** (executable) — the menu bar shell. Untested; all programmatic AppKit, no SwiftUI, no XIB/storyboard.

### AppKit lifecycle is hand-rolled — do not "modernize" it

`main.swift` does not use `@main` or `NSApplicationMain`. It manually calls `finishLaunching()`, then invokes `applicationDidFinishLaunching` directly, then `application.run()`. The `didInitialize` guard in the delegate exists because this manual dispatch can otherwise fire the callback twice. Switching to `@main`/`NSApplicationMain` will break startup.

The app is a menu-bar-only accessory: `LSUIElement` is true in `Info.plist` and `setActivationPolicy(.accessory)` is set, so there is no Dock icon. A singleton guard in `applicationDidFinishLaunching` terminates any second instance by comparing bundle identifier against `runningApplications`.

### Storage

`ClipboardStore` talks to SQLite through the raw `import SQLite3` C API — there is no wrapper library. One table:

```sql
clips (id TEXT PRIMARY KEY, created_at REAL, kind INTEGER, payload BLOB)
```

`kind` 0 = text, 1 = image. `payload` holds the raw bytes (UTF-8 for text, raw image data for images), not JSON — `ClipPayload`'s discriminator is re-encoded into the `kind` column rather than serialized. The default path is `~/Library/Application Support/ClipboardManager/history.sqlite3`; `ClipboardStore.temporary()` is the test factory.

`maxEntries` (default 500) is enforced by calling `trim()` at the end of every `insert`, which deletes all but the newest N rows. It is not a background job.

Row ids are written as `UUID.uuidString`, which is uppercase, and `promote(id:)` / `delete(id:)`
match on it with `=`. SQLite compares TEXT case-sensitively, so a lowercase id — say, one inserted
by hand while fixture-building — silently matches nothing and the delete appears to do nothing.

`ClipboardStore` is a `@unchecked Sendable` class wrapping a non-thread-safe `sqlite3` handle. In practice it is only ever touched from the main actor, so the annotation is an assertion about call sites, not a guarantee — keep it that way rather than moving store access to a background queue.

Search (`list(query:)`) casts the payload blob to text and does a `LIKE` match, and filters to `kind = 0`, so **images are never returned by a text query**.

### Clipboard capture

`MacClipboardMonitor` polls `NSPasteboard.general` on a main-queue `DispatchSource` timer (0.25s default), comparing `changeCount` — it does not use pasteboard change notifications. Reading priority is string → PNG → TIFF. `pollNow()` exists so tests and first-launch reads are deterministic.

Dedup is `ClipNormalizer`, which only remembers the single most recent accepted value. It suppresses the immediate re-read that follows a pasteboard write, but re-copying an older history entry still inserts a new row.

Selecting an entry writes it to `NSPasteboard.general` and then pastes it into the app that was
frontmost when the shortcut fired (`AppDelegate.presentHistory` → `AutoPaster`). That write
round-trips through the same monitor path, so `presentHistory` does two extra things: it promotes
the row the content came from (`ClipboardStore.promote(id:)`, a primary-key timestamp update) and
tells the monitor it already holds that value (`MacClipboardMonitor.markHandled(_:)`, which feeds
the normalizer). Drop either call and reusing an entry stores a **second copy** of content the
history already holds — `recopyingWithoutMarkingItCapturesADuplicate` pins down that failure and
`markHandledSuppressesRecaptureOfAReusedEntry` the fix. Both calls must follow the pasteboard write
before the monitor's next poll; they are safe because `presentHistory` and the monitor both run on
the main actor.

"清空历史" (`AppDelegate.clearHistory`) empties the store and resets the normalizer in the same
step. The reset is not optional: the pasteboard still holds the last copied value, so without it
re-copying that value right after a clear would be dismissed as already seen and the app would look
broken. `resetDeduplicationLetsTheSameValueBeCapturedAgain` pins that down. The confirmation alert
puts "取消" first because `NSAlert` makes the first button the default and Return should not wipe
the history.

### UI layer

Controllers are `@MainActor` and build their UI entirely in code. Settings is a plain `NSWindow`
laid out with `NSLayoutConstraint.activate`, and it sets `isReleasedWhenClosed = false` — the
programmatic default of `true` makes `close()` release the window once more than ARC expects, so
the next `show()` retains freed memory and crashes.

The clipboard history is a **native `NSMenu`** popped at the cursor (`HistoryPanelController`),
not a custom window. That is what supplies the translucent material, rounded corners and
arrow-key navigation for free. `NSMenu.highlightedItem` is read-only, and
`popUp(positioning:at:in:)` puts the positioning item's **top-left corner** on the point it is
given — the menu rounds its origin to the pixel grid, so passing the pointer straight through
leaves it in the padding strip just above the first row. `popUpAnchorOffset` hangs the menu half
a row below and a margin in from the pointer instead, so that the pointer and the marked row agree
from the first frame.

Rows are `HistoryRowView`, a custom `NSMenuItem.view`, because a per-row delete button cannot be
expressed with a plain item. Hosting a view costs three behaviours, and all three are deliberate:

- The menu stops performing click-to-select for that row. `HistoryRowView.mouseDown` selects
  explicitly; without it a click on the row does nothing. Clicks landing on the delete button go
  to the button and never reach `mouseDown`, so no explicit hit test is needed.
- The reveal cannot use `NSTrackingArea`. Measured against a live menu, a tracking area fires only
  when the pointer crosses into it *during* a move and misses when the pointer arrives directly, so
  the button would show up only sometimes. `menu(_:willHighlight:)` is reliable and fires for
  arrow-key selection as well, which is exactly the "hovered or selected" behaviour wanted.
- The selection is **not painted** by the menu, so `HistoryRowView.draw` paints it. The menu still
  tracks the row — `menu(_:willHighlight:)` fires for it and `highlightedItem` reports it — but
  every row of the menu's backing `NSTableViewBackedMenuRepresentation` reports
  `isSelected == false`, so a view-based row with no drawing of its own shows no highlight at all.
  `isHighlighted` drives both that fill and the delete button's reveal.

Menus can be mutated while they are tracking: removing and re-adding items leaves the menu open
and it re-lays out its rows. That is what lets paging and deletion redraw in place instead of
closing and reopening the menu under the pointer.

Because the rows draw their own selection, the marked row is tracked in `highlightedRow` rather
than read back from the menu — the menu is the wrong source for it twice over. It reports `nil`
for the row it has just highlighted (opening sends `willHighlight: row0` and then
`willHighlight: nil`, which is the highlight the user never saw), and `menu(_:willHighlight:)`
therefore ignores `nil` outright; a menu with nothing marked would leave the delete button and the
arrow keys with nothing to sit on. A rebuild then re-applies that index to the new rows, and
paging resets it to the top of the new page.

The paging footer's ‹ › are the pointer's way to turn a page; the bare ← and → keys are the
keyboard's, and they are caught by `HotkeyTap`, not by the menu. So is Return, which picks the
marked entry — without it the only way to choose one is the pointer, because the items carry no
action and the menu does not select a view-based row. A menu that is tracking runs its own Carbon
event loop over these keys and nothing inside the application sees them: measured against a live
menu, a hidden item's key equivalent never fires, `NSMenu.performKeyEquivalent(with:)` is never
called, and a local event monitor never receives the event. The tap sits ahead of all of that, so
`HotkeyTap.install(onUnmodifiedKey:)` hands it the modifier-free keys first and
`HistoryPanelController.handleKey` answers whether it consumed one. Paging is refused outside
`.paged`; Return works in both modes.

Return commits `highlightedRow` rather than row 0, and rather than whatever `highlightedItem`
says — it is the same index the drawing uses. `visibleRecords` is what makes that safe: it is the
single list the menu's rows and `highlightedRow` are both derived from, so "the row that is
painted" and "the row Return picks" cannot drift apart. Committing is `cancelTracking()` plus
setting `pendingSelection`, the same two steps `mouseDown` takes.

Note when verifying any of this: a synthetic key or mouse move cannot be driven into a tracking
menu — measured, posted events never arrive, which is why the arrow-key path could not be checked
by posting arrows. Drive `menu(_:willHighlight:)` directly instead; that is what AppKit's own
navigation calls.

The two entry points present the same records differently. ⌘⇧V is **paged** — 11 entries plus a
footer that carries ‹ › and a page indicator, capped at 3 pages so a long history cannot become an
endless pager. "显示历史" in the status menu is **scrolling**: every entry in one menu, with the
native scrolling that implies. Entries past the last page are therefore reachable only through the
latter. `HistoryPanelController.Mode` picks between them; `presentHistory(mode:)` defaults to
paged, and only `showHistory` passes `.scrolling`.

Three further consequences of building this out of a menu:

- `popUp` runs a nested event loop and returns only once the menu has closed. The selection is
  read *after* it returns, so the synthesized ⌘V is never delivered to the still-tracking menu.
- `AutoPaster` polls `NSRunningApplication.isActive` rather than sleeping a fixed interval, and
  posts ⌘V via `CGEvent` only once the target is frontmost — activation latency varies, and
  pasting early sends the keystroke nowhere. Its `isPasting` flag keeps `presentHistory` from
  starting a second paste while one is in flight.
- The menu has no maximum width or height — `minimumWidth` is a floor, not a ceiling — so
  `HistoryPanelController` holds it to 260×300pt from the content side: a row view `w` points wide
  renders a menu exactly `w` wide (measured, so there is no added horizontal chrome), and a menu
  spends ~12pt vertically on padding, which makes 12 rows of 24pt land on 300pt. Titles are
  truncated by binary search over grapheme clusters against a budget measured in **points** — the
  history mixes Chinese and Latin, so a character count would be wrong for both — and the budget
  comes from `HistoryRowView.titleWidth`, which is what remains once the ordinal column, the
  thumbnail and the delete button are placed. Re-measure after touching any of these.

Rows lead with an ordinal, and it is the entry's position in the **whole history**, not in the
page: page 2 starts at 12, page 3 at 23. The point of it is to be a name for an entry — "复制到第三页
的第6个" should tell the user which entry they are looking at — and a number that restarted at 1 on
every page would say nothing they could not get by counting rows. The column is measured from
`records.count` rather than from the last ordinal on the page, so it keeps its width when the page
turns and the titles do not shift sideways; the digits are monospaced for the same reason. The
ordinal is a position, not a property of the entry: it is not stored, it changes as the history
grows, and it is not part of what the row pastes.

`ShortcutBinding` lives in `SettingsController.swift`, not its own file. The global shortcut is
claimed by a `CGEvent` tap (`HotkeyTap`), **not** `NSEvent.addGlobalMonitorForEvents`: a global
monitor is a read-only observer, so the frontmost application would receive the keystroke too and
act on it. A tap created with `.defaultTap` can drop events, which is what makes the shortcut ours
alone. Both APIs need Accessibility trust, and the tap doubles as the honest test of it — an
untrusted process gets a monitor that silently delivers nothing, but a tap that refuses to install
(`install` returns false, and that is what drives the status-menu warning). `HotkeyTap` re-enables
itself on `tapDisabledByTimeout` and rate-limits auto-repeat. Its C callback takes `keyCode`/`flags`
rather than the `CGEvent`, because `CGEvent` is not `Sendable` under strict concurrency, and
reaches the instance through an **unretained** refcon — so the owner must outlive the tap and call
`remove()`. It carries a second job: `onUnmodifiedKey` is consulted first for keys with no
modifiers, which is how the history menu's paging arrows and its Return key are claimed (see the
UI layer). The menu
item's key equivalent is hardcoded to `⌘⇧V` and does not follow a rebound
shortcut. Shortcut and history limit persist via `UserDefaults` (`historyShortcut` key) and the
store respectively.

## Conventions

- All user-facing strings are Simplified Chinese; match that when adding UI text.
- Comments and identifiers are English.
- `dist/` is tracked in git even though it holds a build artifact. Running `./scripts/build-app.sh` modifies tracked files, so it will show up in `git status`.
