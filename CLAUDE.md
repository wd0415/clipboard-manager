# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

The script signs ad-hoc (`codesign --force --sign -`). An ad-hoc signature carries no Team ID, so
TCC falls back to matching the binary's cdhash — which changes on every rebuild. **Each rebuild
silently invalidates the Accessibility grant.** System Settings keeps showing the toggle as ON,
because that row belongs to the previous build, so the symptom is "the permission is granted but
the shortcut does nothing". Fixing it means re-granting after a rebuild, or signing with a stable
identity so the designated requirement outlives the build. Do not conclude the grant is fine from
System Settings alone.

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

### UI layer

Controllers are `@MainActor` and build their UI entirely in code. Settings is a plain `NSWindow`
laid out with `NSLayoutConstraint.activate`, and it sets `isReleasedWhenClosed = false` — the
programmatic default of `true` makes `close()` release the window once more than ARC expects, so
the next `show()` retains freed memory and crashes.

The clipboard history is a **native `NSMenu`** popped at the cursor (`HistoryPanelController`),
not a custom window. That is what supplies the translucent material, rounded corners, row
highlight, single-line truncation and arrow-key navigation for free. Five consequences to know
before changing it:

- `NSMenu.highlightedItem` is read-only, and passing a `positioningItem` to `popUp(positioning:at:in:)`
  does **not** make it the initial selection (verified empirically — the docs and common advice
  suggest otherwise). The menu therefore opens with no guaranteed highlighted row; a row is only
  highlighted when the pointer happens to rest on it. Arrow keys are the reliable way to select.
- Menu items render images at icon size, so image entries show an 18pt thumbnail, not a preview.
- `popUp` runs a nested event loop and returns only once the menu has closed. The selection is
  read *after* it returns, so the synthesized ⌘V is never delivered to the still-tracking menu.
- `AutoPaster` polls `NSRunningApplication.isActive` rather than sleeping a fixed interval, and
  posts ⌘V via `CGEvent` only once the target is frontmost — activation latency varies, and
  pasting early sends the keystroke nowhere. Its `isPasting` flag keeps `presentHistory` from
  starting a second paste while one is in flight.
- The menu has no maximum width or height — `minimumWidth` is a floor, not a ceiling — so
  `HistoryPanelController` holds it to 260×300pt from the content side: titles are truncated by
  binary search over grapheme clusters against a budget measured in **points** (the history mixes
  Chinese and Latin, so a character count would be wrong for both), and only
  `maxMenuHeight / menuRowHeight` entries are handed to the menu at all. `menuHorizontalChrome`
  was measured rather than estimated — a 200pt title budget rendered a 229pt menu, so the chrome
  is ~30pt. Re-measure after touching any of these constants.

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
`remove()`. The menu item's key equivalent is hardcoded to `⌘⇧V` and does not follow a rebound
shortcut. Shortcut and history limit persist via `UserDefaults` (`historyShortcut` key) and the
store respectively.

## Conventions

- All user-facing strings are Simplified Chinese; match that when adding UI text.
- Comments and identifiers are English.
- `dist/` is tracked in git even though it holds a build artifact. Running `./scripts/build-app.sh` modifies tracked files, so it will show up in `git status`.
