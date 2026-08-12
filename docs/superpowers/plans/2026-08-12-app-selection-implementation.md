# App Selection Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the all-apps-first picker with readable recent, favorite, searchable, and optionally expanded application selection.

**Architecture:** A small `AppSelectionStore` persists only package-name preferences in UserDefaults. `AppModel` joins those preferences to scanned apps and exposes stable recent/favorite sections; SwiftUI derives search and expanded-all results from those sections without touching persistence.

**Tech Stack:** Swift 6, SwiftUI for macOS 13, XCTest, UserDefaults.

## Global Constraints

- macOS 13.0 minimum; arm64 only.
- No log contents, sessions, device serials, or search text may be persisted.
- Personal favorites are local-only; team preset metadata remains read-only.
- Run `make test` after each task; the test target requires approved elevated execution.

---

### Task 1: Persist personal favorites and recents

**Files:**
- Create: `FantaLogcatApp/Apps/AppSelectionStore.swift`
- Create: `FantaLogcatTests/Apps/AppSelectionStoreTests.swift`

**Interfaces:**
- Produces: `AppSelectionStoreProtocol`, `UserDefaultsAppSelectionStore`, `AppSelectionPreferences`.
- Consumes: `AndroidPackageName` only as a validated source at model boundary; store writes `[String]` JSON.

- [ ] **Step 1: Write failing store tests**

```swift
func testToggleFavoritePersistsPackageName() throws {
    let store = UserDefaultsAppSelectionStore(defaults: isolatedDefaults)
    XCTAssertTrue(store.toggleFavorite("com.game.tile"))
    XCTAssertEqual(store.preferences.favoritePackageNames, ["com.game.tile"])
    XCTAssertFalse(store.toggleFavorite("com.game.tile"))
}

func testRecordRecentMovesExistingPackageToFrontAndLimitsSix() {
    let store = UserDefaultsAppSelectionStore(defaults: isolatedDefaults)
    (1...7).forEach { store.recordRecent("com.game.\($0)") }
    store.recordRecent("com.game.4")
    XCTAssertEqual(store.preferences.recentPackageNames, ["com.game.4", "com.game.7", "com.game.6", "com.game.5", "com.game.3", "com.game.2"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`

Expected: compile failure because `UserDefaultsAppSelectionStore` does not exist.

- [ ] **Step 3: Implement the minimal store**

```swift
protocol AppSelectionStoreProtocol: Sendable {
    var preferences: AppSelectionPreferences { get }
    @discardableResult func toggleFavorite(_ packageName: String) -> Bool
    func recordRecent(_ packageName: String)
}
```

Use one namespaced UserDefaults JSON key; decoding failure produces empty preferences. `recordRecent` removes duplicate then prefixes and limits to six.

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add FantaLogcatApp/Apps/AppSelectionStore.swift FantaLogcatTests/Apps/AppSelectionStoreTests.swift
git commit -m "feat: persist favorite and recent apps"
```

### Task 2: Publish selected-app sections from the application model

**Files:**
- Modify: `FantaLogcatApp/Application/AppEnvironment.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`
- Modify: `FantaLogcatTests/Application/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppSelectionStoreProtocol`, `[AppDescriptor]`.
- Produces: `recentApps`, `favoriteApps`, `isFavorite(_:)`, `toggleFavorite(_:)`.

- [ ] **Step 1: Write failing model test**

```swift
func testSelectionRecordsRecentAndFavoriteSectionsOnlyContainInstalledApps() async throws {
    // Configure installed Tile Match and Other App; store holds a missing app favorite.
    // Select Tile Match and star Other App.
    XCTAssertEqual(model.recentApps.map(\.id), ["com.game.tile"])
    XCTAssertEqual(model.favoriteApps.map(\.id), ["com.other.app"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`

Expected: compile failure because the published section properties and favorite action do not exist.

- [ ] **Step 3: Implement the minimal model projection**

Inject the store through `AppEnvironment`; after successful app scan and after favorite/recent mutation, map stored package names to the current `availableApps`. `selectApp` records recent before opening the log stream. The public sections must never include an uninstalled package.

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add FantaLogcatApp/Application/AppEnvironment.swift FantaLogcatApp/Application/AppModel.swift FantaLogcatTests/Application/AppModelTests.swift
git commit -m "feat: expose recent and favorite app sections"
```

### Task 3: Replace the picker layout

**Files:**
- Modify: `FantaLogcatApp/UI/AppSelectionView.swift`

**Interfaces:**
- Consumes: `AppModel.recentApps`, `favoriteApps`, `availableApps`, `isFavorite`, `toggleFavorite`.

- [ ] **Step 1: Add pure view-state tests if a testable helper is extracted**

```swift
XCTAssertEqual(AppSelectionPresentation.searchResults(apps, query: "com.game"), [tile])
XCTAssertEqual(AppSelectionPresentation.otherApps(apps, recent: [tile], favorites: [other]), [third])
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`

Expected: compile failure for the extracted helper, if used.

- [ ] **Step 3: Implement the SwiftUI layout**

Use a scrollable page with a title, refresh control, large search field, `最近查看` and `常用应用` sections, and a collapsed `浏览全部已安装应用` disclosure. Each `AppRow` has a large primary display name, monospaced full package ID, team badge for preset provenance, and a separately clickable star button. Search overrides normal sections and displays all matched apps. The no-default-results state provides both search guidance and the disclosure entry.

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add FantaLogcatApp/UI/AppSelectionView.swift FantaLogcatTests
git commit -m "feat: simplify application picker"
```

### Task 4: Release verification

**Files:**
- Verify: `build/DerivedData/Build/Products/Release/FantaLogcat.app`

- [ ] **Step 1: Run full tests**

Run: `make test`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build Release app**

Run: `make build && codesign --verify --deep --strict build/DerivedData/Build/Products/Release/FantaLogcat.app`

Expected: `** BUILD SUCCEEDED **` and code-sign verification exits 0.

- [ ] **Step 3: Commit any generated-project changes if applicable**

```bash
git status --short
```

Expected: clean worktree after source commits; generated Xcode project changes are committed only if source-controlled and changed intentionally.

### Task 5: Resolve real Android application labels

**Files:**
- Modify: `FantaLogcatApp/ADB/ADBCommand.swift`
- Modify: `FantaLogcatApp/Apps/AppCatalog.swift`
- Modify: `FantaLogcatApp/UI/AppSelectionView.swift`
- Modify: `FantaLogcatTests/Apps/AppCatalogTests.swift`

**Interfaces:**
- Produces: `ADBCommand.applicationLabel`, `AppCatalog` label parsing and safe fallback behavior.

- [ ] **Step 1: Write failing catalog tests**

```swift
func testGenericAppUsesAndroidApplicationLabel() async throws {
    let catalog = AppCatalog(adb: StubAppADB(packages: ["com.game.tile"], applicationLabels: ["com.game.tile": "Tile Match"]))
    XCTAssertEqual(try await catalog.listApps(on: device).first?.presentation.displayName, "Tile Match")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`

Expected: compile failure because `applicationLabel` query is not implemented.

- [ ] **Step 3: Implement bounded application-label enrichment**

Add a serial- and package-scoped command using `dumpsys package <package>`. Parse `application-label:` lines, preferring a nonempty value and rejecting control characters. Preserve team preset names. Enrich only generic apps on explicit full-list/search access; cache successful name values for the current run and preferred local entry. Never make an app list fail because a label lookup fails.

- [ ] **Step 4: Remove the decorative app-row icon**

Retain first-line display name, package ID, team badge, app selection, and favorite action; remove the left icon so every remaining element is functional.

- [ ] **Step 5: Run verification and commit**

Run: `make test && make build`

Expected: all tests pass and Release build succeeds.

```bash
git add FantaLogcatApp FantaLogcatTests docs/superpowers
git commit -m "feat: show Android application labels"
```
