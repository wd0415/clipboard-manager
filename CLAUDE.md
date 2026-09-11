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

Writing back from the history panel (`HistoryPanelController.selectItem`) clears and repopulates `NSPasteboard.general`, so it round-trips through the same monitor path.

### UI layer

Controllers are `@MainActor` and build their windows entirely in code with `NSStackView` + `NSLayoutConstraint.activate`. The history panel is a floating `.nonactivatingPanel` positioned near the cursor and clamped to the active screen's `visibleFrame`.

`ShortcutBinding` lives in `SettingsController.swift`, not its own file. The global shortcut is registered with `NSEvent.addGlobalMonitorForEvents`, which requires the user to grant Accessibility permission; the menu item's key equivalent is hardcoded to `⌘⇧V` and does not follow a rebound shortcut. Shortcut and history limit persist via `UserDefaults` (`historyShortcut` key) and the store respectively.

## Conventions

- All user-facing strings are Simplified Chinese; match that when adding UI text.
- Comments and identifiers are English.
- `dist/` is tracked in git even though it holds a build artifact. Running `./scripts/build-app.sh` modifies tracked files, so it will show up in `git status`.
