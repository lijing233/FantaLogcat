# Log View Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make live Logcat browsing beginner-friendly through quick level filters, keyword search and saved keywords, pause/resume presentation, and reliable follow-to-latest behavior.

**Architecture:** Keep the existing `LogRingBuffer` as the sole bounded source of retained events. `AppModel` owns user-visible filter and presentation state; it continues ingesting while presentation is paused, then publishes one fresh bounded snapshot on resume. `LogView` owns only scroll-position mechanics and renders `AppModel`'s filtered event collection.

**Tech Stack:** Swift 6, SwiftUI, Combine `ObservableObject`, XCTest, macOS 13+ arm64.

## Global Constraints

- Retain at most 100,000 events and 128 MiB of `message`/`rawText` content.
- Pausing must never stop ADB capture or clear the retained log buffer.
- Keyword matching is local, case-insensitive literal matching over message, Android tag, and business tag.
- Saved keywords are local-only; no log content or log sessions are persisted.
- UI updates remain batched; filtering must not start an additional ADB process.

---

### Task 1: Filter and saved-keyword domain

**Files:**
- Create: `FantaLogcatApp/Logs/LogFiltering.swift`
- Create: `FantaLogcatApp/Logs/LogKeywordStore.swift`
- Create: `FantaLogcatTests/Logs/LogFilteringTests.swift`
- Create: `FantaLogcatTests/Logs/LogKeywordStoreTests.swift`

**Interfaces:**
- Produces `LogFilter`, `SavedKeyword`, `LogKeywordStoreProtocol`, and `UserDefaultsLogKeywordStore`.
- Consumed by `AppModel` and `LogView`.

- [ ] **Step 1: Write failing filtering tests**

```swift
func testFilterCombinesSelectedLevelsAndKeywordAcrossMessageAndTags() {
    let filter = LogFilter(levels: [.warning, .error], keyword: "network")
    XCTAssertEqual(filter.apply(events).map(\.id), [2, 3])
}

func testEmptyKeywordKeepsSelectedLevelsWithoutTreatingWhitespaceAsAQuery() {
    let filter = LogFilter(levels: [.error], keyword: "   ")
    XCTAssertEqual(filter.apply(events).map(\.id), [3])
}
```

- [ ] **Step 2: Run `LogFilteringTests` and confirm compilation failure because `LogFilter` does not exist.**

- [ ] **Step 3: Implement literal filtering**

```swift
struct LogFilter: Sendable, Equatable {
    var levels: Set<LogPriority>
    var keyword: String

    func apply(_ events: [LogEvent]) -> [LogEvent] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            (levels.isEmpty || levels.contains(event.priority))
                && (query.isEmpty || event.searchableText.localizedCaseInsensitiveContains(query))
        }
    }
}
```

- [ ] **Step 4: Write failing persistence tests**

```swift
func testSavingKeywordDeduplicatesAndMovesItToTheFront() {
    let store = InMemoryLogKeywordStore()
    store.save("Unity")
    store.save("Exception")
    store.save("Unity")
    XCTAssertEqual(store.keywords.map(\.value), ["Unity", "Exception"])
}
```

- [ ] **Step 5: Implement the store with a six-keyword maximum and `UserDefaults` production implementation.**

- [ ] **Step 6: Run the two test classes and commit the domain layer.**

### Task 2: Bounded presentation controls in `AppModel`

**Files:**
- Modify: `FantaLogcatApp/Application/AppEnvironment.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`
- Modify: `FantaLogcatTests/Application/AppModelTests.swift`

**Interfaces:**
- Consumes `LogFilter`, `LogKeywordStoreProtocol`, and `LogRingBuffer`.
- Produces `filteredLogEvents`, `isLogPresentationPaused`, `pendingLogEventCount`, `setLogLevels(_:)`, `setLogKeyword(_:)`, `pauseLogPresentation()`, and `resumeLogPresentation()`.

- [ ] **Step 1: Write failing behavior tests**

```swift
func testPausingPresentationStillRetainsNewEventsUntilResume() async throws {
    model.pauseLogPresentation()
    await session.emit(.fixture(id: 2, message: "later"))
    XCTAssertEqual(model.logEvents.map(\.id), [1])
    XCTAssertEqual(model.pendingLogEventCount, 1)
    await model.resumeLogPresentation()
    XCTAssertEqual(model.logEvents.map(\.id), [1, 2])
}

func testKeywordAndLevelSelectionPublishOnlyMatchingEvents() {
    model.setLogLevels([.error])
    model.setLogKeyword("Unity")
    XCTAssertEqual(model.filteredLogEvents.map(\.id), [3])
}
```

- [ ] **Step 2: Run the selected `AppModelTests` and confirm failure for the missing controls.**

- [ ] **Step 3: Add the keyword-store factory to `AppEnvironment`; inject a deterministic in-memory implementation into tests.**

- [ ] **Step 4: Implement paused presentation**

Append incoming events to the existing `LogRingBuffer` in every state. When paused, do not replace `logEvents`; increment `pendingLogEventCount`. On resume, take one `.all` snapshot, reset the pending count, and publish it. Clear and app-switch reset pause state and pending count.

- [ ] **Step 5: Implement `filteredLogEvents` as a consumer-facing computed collection derived from `logEvents` and `LogFilter`; persist only saved keyword values.**

- [ ] **Step 6: Run all `AppModelTests` and commit presentation controls.**

### Task 3: Log toolbar, auto-follow, and readable timeline

**Files:**
- Modify: `FantaLogcatApp/UI/LogView.swift`
- Create: `FantaLogcatTests/Logs/LogViewStateTests.swift` if presentation logic is extracted.

**Interfaces:**
- Consumes `AppModel.filteredLogEvents`, selected levels, saved keywords, pause state, and pending count.
- Produces level controls, searchable log display, save-keyword action, pause/resume, and follow-to-latest interaction.

- [ ] **Step 1: Extract and test pure follow-button copy**

```swift
func testFollowCopyUsesPendingCountWhenNewEventsArrive() {
    XCTAssertEqual(LogFollowPresentation.copy(for: 7), "7 new logs · Jump to latest")
}
```

- [ ] **Step 2: Run the test and confirm the helper is missing.**

- [ ] **Step 3: Implement the toolbar**

Place `All`, `W+`, and `Errors` quick presets beside compact multi-select level chips. Add a search field with clear button and a star action that saves a nonempty keyword. Render saved keywords as removable chips under the search field.

- [ ] **Step 4: Implement follow-to-latest**

Wrap the list in `ScrollViewReader`; use a stable bottom anchor after the final filtered row. Follow is enabled when the view opens and when the user presses `Jump to latest`; it scrolls after each published batch. The pause button stops visual updates independently of this control. Show `N new logs · Jump to latest` whenever logs arrive while follow is disabled.

- [ ] **Step 5: Improve the empty state**

Differentiate no captured logs, no logs matching current filters, and paused presentation. Offer `Clear filters` in the filtered-empty state.

- [ ] **Step 6: Run UI-state tests and the full test suite; commit the view work.**

### Task 4: Verification and device acceptance

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-fantalogcat-completion-design.md`

- [ ] **Step 1: Update the completed design with actual keyboard shortcuts and persisted-keyword scope.**

- [ ] **Step 2: Run `make test`; require all tests to pass.**

- [ ] **Step 3: Run `make build`; require the arm64 Release app to be produced.**

- [ ] **Step 4: On a connected Android device, verify:**

1. New logs follow to the bottom.
2. Clicking Pause freezes the rendered list while the pending count increases.
3. Resume shows retained logs without restarting ADB.
4. `Errors` and a keyword reduce the visible set correctly.
5. A saved keyword remains after reopening the app.
6. Leaving the log page releases the current session cache.

- [ ] **Step 5: Inspect `git diff --check`, review the final diff, and commit the documentation update.**
