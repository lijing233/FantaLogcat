# FantaLogcat Interaction and Open-Source Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make log search and settings behavior predictable and accessible, then complete the files and automated checks required for a public source repository.

**Architecture:** Move persisted app preferences behind one settings-store boundary and edit a value-type draft in the settings sheet. Extract the keyword-query editor state from `LogView` so add/clear behavior can be tested independently while `AppModel` owns the canonical “clear all filters” operation. Keep repository checks in executable scripts called identically by Make and GitHub Actions.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest/XCUITest, Xcode 26.6, XcodeGen 2.46.0 through Mint, POSIX shell, GitHub Actions.

## Global Constraints

- Support macOS 13+ on Apple Silicon (`arm64`).
- Closing Settings, pressing Escape, or dismissing the sheet must discard language and log-setting edits; only Save persists them.
- Settings may preview the draft language inside the sheet, but the main window must not change before Save.
- Search keeps the existing keyword-chip and OR/AND query model; do not add a query-language editor or automatic keyword deduplication.
- Clearing filters resets selected priorities, committed keyword chips, the generated query, and the uncommitted input draft.
- Do not create or configure a remote repository, push, notarize, or publish a GitHub Release.
- Public source and built app artifacts must not contain `Config/TeamConfig.json`.
- Use the unmodified Apache License 2.0 text; do not invent a security email address.

---

## File Structure

- `FantaLogcatApp/Application/AppSettings.swift`: value types and persistence protocol for language plus capture settings.
- `FantaLogcatApp/Application/AppModel.swift`: owns the current effective settings, atomic settings commit, and canonical filter reset.
- `FantaLogcatApp/Logs/LogSearchBuilder.swift`: testable keyword chips, draft, operator, query generation, and reset behavior.
- `FantaLogcatApp/UI/SettingsView.swift`: draft-only editor with Save and Close actions.
- `FantaLogcatApp/UI/LogView.swift`: larger search controls, adaptive saved-keyword layout, help/accessibility, and shared clear behavior.
- `FantaLogcatApp/Application/FantaLogcatApp.swift`: deterministic UI-test launch surfaces only when explicit test arguments are present.
- `FantaLogcatTests/Application/AppSettingsTests.swift`, `FantaLogcatTests/Application/AppModelTests.swift`, `FantaLogcatTests/Logs/LogSearchBuilderTests.swift`: behavior tests for settings and search state.
- `FantaLogcatUITests/InteractionUITests.swift`: Save/Close and add/clear paths using stable accessibility identifiers.
- `Scripts/check-public-release.sh`, `Scripts/test-public-release-check.sh`: public-source and built-artifact checks plus fixture-driven script tests.
- `Makefile`, `.github/workflows/ci.yml`: common local/CI verification and release packaging.
- Public documentation and templates live at the repository root, `.github/`, and `docs/RELEASE_CHECKLIST.md`.

### Task 1: Atomic application settings domain

**Files:**
- Create: `FantaLogcatApp/Application/AppSettings.swift`
- Create: `FantaLogcatTests/Application/AppSettingsTests.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`
- Modify: `FantaLogcatApp/Logs/LogCaptureSettings.swift`
- Modify: `FantaLogcatTests/Application/AppModelTests.swift`

**Interfaces:**
- Produces: `AppSettings(language:capture:)`, `AppSettingsStore.settings`, `AppSettingsStore.save(_:)`, `AppModel.settingsDraft`, and `AppModel.saveSettings(_:)`.
- Consumes: existing `AppLanguage`, `LogCaptureSettings.normalized`, and `UserDefaults` storage keys.

- [ ] **Step 1: Write failing store and model tests.**

```swift
func testUserDefaultsStoreRoundTripsLanguageAndNormalizedCaptureSettings() {
    let defaults = UserDefaults(suiteName: #function)!
    defaults.removePersistentDomain(forName: #function)
    let store = UserDefaultsAppSettingsStore(defaults: defaults)
    store.save(AppSettings(
        language: .english,
        capture: .init(historyLines: 999, maxEvents: 500, maxTextBytes: 1, redactExportsByDefault: false)
    ))

    XCTAssertEqual(store.settings.language, .english)
    XCTAssertEqual(store.settings.capture.historyLines, 500)
    XCTAssertEqual(store.settings.capture.maxEvents, 1_000)
    XCTAssertEqual(store.settings.capture.maxTextBytes, 8 * 1_024 * 1_024)
    XCTAssertFalse(store.settings.capture.redactExportsByDefault)
}

@MainActor
func testSaveSettingsAppliesAllFieldsAndPersistsOnce() {
    let store = InMemoryAppSettingsStore(settings: .init(language: .chinese, capture: .init()))
    let model = AppModel(environment: .test(), settingsStore: store)
    let draft = AppSettings(language: .english, capture: .init(historyLines: 100, maxEvents: 5_000, maxTextBytes: 16 * 1_024 * 1_024, redactExportsByDefault: false))

    model.saveSettings(draft)

    XCTAssertEqual(model.language, .english)
    XCTAssertEqual(model.captureSettings, draft.capture)
    XCTAssertEqual(store.savedValues, [draft])
}
```

- [ ] **Step 2: Run the focused tests and verify RED.**

Run: `make generate && xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/AppSettingsTests -only-testing:FantaLogcatTests/AppModelTests test`

Expected: compilation fails because `AppSettings`, the store types, and `saveSettings` do not exist.

- [ ] **Step 3: Implement the minimal settings boundary.**

```swift
struct AppSettings: Equatable, Sendable {
    var language: AppLanguage
    var capture: LogCaptureSettings

    var normalized: AppSettings {
        AppSettings(language: language, capture: capture.normalized)
    }
}

protocol AppSettingsStore: Sendable {
    var settings: AppSettings { get }
    func save(_ settings: AppSettings)
}

final class UserDefaultsAppSettingsStore: AppSettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var settings: AppSettings {
        let language = AppLanguage(
            rawValue: defaults.string(forKey: AppLanguage.storageKey) ?? ""
        ) ?? .chinese
        let capture = defaults.data(forKey: LogCaptureSettings.storageKey)
            .flatMap { try? JSONDecoder().decode(LogCaptureSettings.self, from: $0) }
            ?? LogCaptureSettings()
        return AppSettings(language: language, capture: capture).normalized
    }
    func save(_ settings: AppSettings) {
        let value = settings.normalized
        defaults.set(value.language.rawValue, forKey: AppLanguage.storageKey)
        defaults.set(try? JSONEncoder().encode(value.capture), forKey: LogCaptureSettings.storageKey)
    }
}
```

Initialize `AppModel` from an injected store, expose `settingsDraft` as a fresh value, and make `saveSettings(_:)` normalize once, update both published values, then call `store.save`. Remove UI usage of the old partial persistence methods; retain compatibility helpers only if another production caller still requires them.

- [ ] **Step 4: Run the focused tests and verify GREEN.**

Run the command from Step 2.

Expected: `AppSettingsTests` and `AppModelTests` pass without warnings.

- [ ] **Step 5: Commit the atomic settings domain.**

```bash
git add FantaLogcatApp/Application/AppSettings.swift FantaLogcatApp/Application/AppModel.swift FantaLogcatApp/Logs/LogCaptureSettings.swift FantaLogcatTests/Application/AppSettingsTests.swift FantaLogcatTests/Application/AppModelTests.swift
git commit -m "refactor: make app settings atomic"
```

### Task 2: Transactional Settings sheet

**Files:**
- Modify: `FantaLogcatApp/UI/SettingsView.swift`
- Modify: `FantaLogcatApp/UI/RootView.swift`
- Modify: `FantaLogcatApp/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `AppModel.settingsDraft`, `AppModel.saveSettings(_:)`, and sheet binding `AppModel.isShowingSettings`.
- Produces: settings controls `settings.language`, `settings.close`, and `settings.save` accessibility identifiers.

- [ ] **Step 1: Add a compile-time failing call site for the new draft initializer.**

Update `RootView` to construct `SettingsView(initialDraft: model.settingsDraft)` while the old view has no such initializer. This is a UI composition contract; behavior is protected by Task 1 tests and Task 4 XCUITests.

- [ ] **Step 2: Run a build and verify RED.**

Run: `make generate && xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build`

Expected: compilation fails because `SettingsView(initialDraft:)` is unavailable.

- [ ] **Step 3: Implement a local `@State` draft and explicit actions.**

```swift
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppSettings

    init(initialDraft: AppSettings) {
        _draft = State(initialValue: initialDraft)
    }

    private func close() { dismiss() }
    private func save() {
        model.saveSettings(draft)
        dismiss()
    }
}
```

Render every string through `draft.language` so only the sheet previews the language. Bind all controls to `draft.capture`. Add a bordered Close button with `.keyboardShortcut(.cancelAction)` and a prominent Save button with `.keyboardShortcut(.defaultAction)`. Apply the identifiers listed above and concise help text. No control may call `UserDefaults` or mutate `AppModel` before Save.

- [ ] **Step 4: Build and run the settings/model tests.**

Run: `make generate && xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/AppSettingsTests -only-testing:FantaLogcatTests/AppModelTests test`

Expected: build succeeds and focused tests pass.

- [ ] **Step 5: Commit the Settings sheet.**

```bash
git add FantaLogcatApp/UI/SettingsView.swift FantaLogcatApp/UI/RootView.swift FantaLogcatApp/Resources/Localizable.xcstrings
git commit -m "feat: save settings transactionally"
```

### Task 3: Testable search builder and canonical filter reset

**Files:**
- Create: `FantaLogcatApp/Logs/LogSearchBuilder.swift`
- Create: `FantaLogcatTests/Logs/LogSearchBuilderTests.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`
- Modify: `FantaLogcatTests/Application/AppModelTests.swift`

**Interfaces:**
- Produces: `KeywordOperator`, `SelectedKeyword`, `LogSearchBuilder.addDraft()`, `addKeyword(_:)`, `remove(id:)`, `clear()`, `query`, and `AppModel.clearLogFilters()`.
- Consumes: existing `LogFilter` and its OR/AND parser.

- [ ] **Step 1: Write failing state-transition tests.**

```swift
func testAddingDraftBuildsQueryWithSelectedOperator() {
    var builder = LogSearchBuilder()
    builder.draft = " Unity "
    builder.addDraft()
    builder.nextOperator = .and
    builder.draft = "Exception"
    builder.addDraft()

    XCTAssertEqual(builder.query, "Unity AND Exception")
    XCTAssertEqual(builder.draft, "")
}

func testClearRemovesDraftKeywordsAndRestoresDefaultOperator() {
    var builder = LogSearchBuilder(draft: "pending", keywords: [.init(value: "Unity", relation: nil)], nextOperator: .and)
    builder.clear()

    XCTAssertEqual(builder, LogSearchBuilder())
}

@MainActor
func testClearLogFiltersRestoresAllLevelsAndEmptyKeyword() {
    let model = AppModel(environment: .test(), settingsStore: InMemoryAppSettingsStore())
    model.setLogLevels([.error])
    model.setLogKeyword("Unity")
    model.clearLogFilters()

    XCTAssertEqual(model.logFilter, LogFilter())
}
```

- [ ] **Step 2: Run focused tests and verify RED.**

Run: `make generate && xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/LogSearchBuilderTests -only-testing:FantaLogcatTests/AppModelTests test`

Expected: compilation fails for the missing search builder and clear operation.

- [ ] **Step 3: Implement minimal value semantics and filter reset.**

Use trimmed nonempty keywords, preserve explicit duplicates, set the first relation to `nil`, default subsequent relations to `nextOperator`, and generate exactly the existing `OR`/`AND` query syntax. `AppModel.clearLogFilters()` assigns a fresh `LogFilter()` so level and keyword state cannot diverge.

- [ ] **Step 4: Run focused and existing filtering tests and verify GREEN.**

Run: `make generate && xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/LogSearchBuilderTests -only-testing:FantaLogcatTests/LogFilteringTests -only-testing:FantaLogcatTests/AppModelTests test`

Expected: all selected tests pass.

- [ ] **Step 5: Commit the search domain.**

```bash
git add FantaLogcatApp/Logs/LogSearchBuilder.swift FantaLogcatApp/Application/AppModel.swift FantaLogcatTests/Logs/LogSearchBuilderTests.swift FantaLogcatTests/Application/AppModelTests.swift
git commit -m "refactor: centralize log search state"
```

### Task 4: Search UI hierarchy, accessibility, and UI regression paths

**Files:**
- Modify: `FantaLogcatApp/UI/LogView.swift`
- Modify: `FantaLogcatApp/Application/FantaLogcatApp.swift`
- Modify: `project.yml`
- Create: `FantaLogcatUITests/InteractionUITests.swift`

**Interfaces:**
- Consumes: `LogSearchBuilder` and `AppModel.clearLogFilters()`.
- Produces: identifiers `logSearch.input`, `logSearch.add`, `logSearch.favorite`, `logSearch.clear`, `logSearch.operator.or`, `logSearch.operator.and`, plus deterministic `--ui-testing-settings` and `--ui-testing-search` launch surfaces.

- [ ] **Step 1: Write XCUITests for the missing interactions.**

```swift
func testClosingSettingsDiscardsLanguageChange() {
    app.launchArguments = ["--ui-testing-settings"]
    app.launch()
    app.segmentedControls["settings.language"].buttons["English"].click()
    app.buttons["settings.close"].click()
    app.terminate()
    app.launch()
    XCTAssertTrue(app.segmentedControls["settings.language"].buttons["简体中文"].isSelected)
}

func testSearchAddAndClearUseVisibleButtons() {
    app.launchArguments = ["--ui-testing-search"]
    app.launch()
    app.textFields["logSearch.input"].typeText("Unity")
    app.buttons["logSearch.add"].click()
    XCTAssertTrue(app.staticTexts["Unity"].exists)
    app.buttons["logSearch.clear"].click()
    XCTAssertFalse(app.staticTexts["Unity"].exists)
}
```

Add a parallel settings Save test that relaunches and observes English selected. Reset the UI-test defaults keys on the first launch of each test with `--ui-testing-reset`; omit that argument on the verifying relaunch so persistence is observable. Add `FantaLogcatUITests` to the scheme's test targets in `project.yml`.

- [ ] **Step 2: Run UI tests and verify RED.**

Run: `make generate && xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatUITests/InteractionUITests test`

Expected: tests fail because launch surfaces and identifiers do not exist.

- [ ] **Step 3: Implement the larger, adaptive search control.**

Replace the icon-only add action with `Label(copy("添加", "Add"), systemImage: "plus")`, `.buttonStyle(.borderedProminent)`, and `.controlSize(.large)`. Give the input matching vertical size and a sensible minimum width. Present favorite as a labeled secondary button; group OR/AND under “下一个条件 / Next condition”; use `LazyVGrid` with adaptive columns for saved keywords. Buttons must have `.help`, identifiers, and at least a 28×28 interactive frame. Escape clears only a nonempty draft; both clear buttons call one view helper that invokes `builder.clear()` and `model.clearLogFilters()`.

- [ ] **Step 4: Add deterministic UI-test surfaces without changing normal launch.**

Read explicit process arguments once. Under `--ui-testing-settings`, show a sheet host without starting ADB preparation; under `--ui-testing-search`, render the extracted production search editor with an in-memory model. Normal launches continue to render `RootView` unchanged. `--ui-testing-reset` clears only FantaLogcat preference keys before constructing the model.

- [ ] **Step 5: Run UI tests, unit tests, and a release build.**

Run: `make test && make build`

Expected: unit/UI tests pass; Release build succeeds with no Swift warnings.

- [ ] **Step 6: Commit the interaction UI.**

```bash
git add FantaLogcatApp/UI/LogView.swift FantaLogcatApp/Application/FantaLogcatApp.swift FantaLogcatUITests/InteractionUITests.swift project.yml
git commit -m "feat: improve log search interactions"
```

### Task 5: Public repository documentation and contribution templates

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Create: `NOTICE`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `CODE_OF_CONDUCT.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature_request.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`
- Create: `.github/PULL_REQUEST_TEMPLATE.md`
- Create: `docs/RELEASE_CHECKLIST.md`

**Interfaces:**
- Consumes: verified commands `make generate`, `make test`, `make build`, and `make release`.
- Produces: complete public onboarding, contribution, conduct, security, issue, PR, and release procedures.

- [ ] **Step 1: Draft README from the implemented product behavior.**

Document: FantaLogcat’s selected-process Logcat workflow; macOS 13+ arm64 requirement; managed official Platform-Tools download and SHA-256 verification; USB authorization; unsigned local-build Gatekeeper flow through System Settings; in-memory logs; local-only favorites/settings; optional export redaction limits; build/test commands; known 1.0 limits; and links to all public policy documents. Omit the screenshot section until a real checked-in screenshot exists; do not add a broken image link.

- [ ] **Step 2: Add exact legal and community documents.**

Copy the unmodified Apache License 2.0 text into `LICENSE`. `NOTICE` attributes Android Debug Bridge/AOSP without endorsement language. Use Contributor Covenant 2.1 in `CODE_OF_CONDUCT.md`, directing enforcement reports to GitHub’s private reporting/contact mechanism. `SECURITY.md` supports the latest release and directs vulnerabilities to GitHub Private Vulnerability Reporting.

- [ ] **Step 3: Add actionable contributor and release procedures.**

`CONTRIBUTING.md` pins Xcode 26.6, Mint 0.18.0, XcodeGen 2.46.0, Swift 6 language mode, test commands, TDD expectation, and the prohibition on committing `Config/TeamConfig.json`. `docs/RELEASE_CHECKLIST.md` includes clean checkout, unit/UI tests, USB and wireless real-device checks, Unity exception/ANR cases, long-session memory behavior, export/redaction inspection, public-artifact scan, checksum, signing/notarization, and manual GitHub Release publication.

- [ ] **Step 4: Add structured issue and PR templates.**

Bug reports request FantaLogcat version/commit, macOS version, Mac architecture, Android version, USB/wireless connection, reproducible steps, expected/actual behavior, and confirmation that attached logs contain no secrets. Feature requests ask for the debugging problem and minimal desired outcome. PRs require test evidence, screenshots for UI changes, privacy review, and confirmation that team configuration is absent.

- [ ] **Step 5: Review prose for accuracy and commit.**

Run: `rg -n "TBD|TODO|your-email|example\.com|Config/TeamConfig\.json" README.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md NOTICE docs/RELEASE_CHECKLIST.md .github`

Expected: only the intentional private-config warnings match; no placeholder contact details or unfinished prose appear.

```bash
git add README.md LICENSE NOTICE CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md .github/ISSUE_TEMPLATE .github/PULL_REQUEST_TEMPLATE.md docs/RELEASE_CHECKLIST.md
git commit -m "docs: prepare repository for open source"
```

### Task 6: Executable public-release checks and CI

**Files:**
- Create: `Scripts/check-public-release.sh`
- Create: `Scripts/test-public-release-check.sh`
- Create: `.github/workflows/ci.yml`
- Modify: `Makefile`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `make check-public`, `make test-release-check`, `make ci`, and a `release` target that writes `FantaLogcat-macos-arm64.zip.sha256`.
- Consumes: optional `SOURCE_ROOT` and `APP_PATH` environment variables so the checker can run against fixtures and a built app.

- [ ] **Step 1: Write the failing fixture-driven script tests.**

`Scripts/test-public-release-check.sh` creates isolated temporary source/app fixtures and asserts these observable outcomes:

```sh
expect_success clean_source_and_app env SOURCE_ROOT="$clean_source" APP_PATH="$clean_app" "$checker"
expect_failure team_config_in_source env SOURCE_ROOT="$source_with_team_config" "$checker"
expect_failure team_config_in_bundle env SOURCE_ROOT="$clean_source" APP_PATH="$app_with_team_config" "$checker"
expect_failure missing_required_document env SOURCE_ROOT="$source_without_readme" "$checker"
```

The script must clean its own `mktemp -d` directory with a trap and print the named failed case before exiting nonzero.

- [ ] **Step 2: Run the script tests and verify RED.**

Run: `chmod +x Scripts/test-public-release-check.sh && Scripts/test-public-release-check.sh`

Expected: failure because `check-public-release.sh` is missing.

- [ ] **Step 3: Implement the checker and Make targets.**

The checker validates required public documents, rejects an existing `Config/TeamConfig.json`, scans tracked source paths and the optional app bundle for the private filename, checks the app executable when `APP_PATH` is supplied, and prints one concise success line. `make release` runs the checker before packaging, validates arm64 with `lipo -archs`, creates the ZIP, and writes `shasum -a 256` output to `$(RELEASE_ZIP).sha256`.

- [ ] **Step 4: Verify script behavior GREEN.**

Run: `Scripts/test-public-release-check.sh && make check-public`

Expected: every fixture case behaves as asserted and the real source tree passes.

- [ ] **Step 5: Add CI using the same Make entry points.**

Create a least-privilege workflow with `contents: read`, concurrency cancellation, a supported macOS runner, Mint installation, `make ci`, `make release`, and artifact upload for the ZIP/checksum only. `make ci` runs `test-release-check` and `test`; no workflow step pushes tags or creates releases.

- [ ] **Step 6: Run the complete local release pipeline.**

Run: `make ci && make release && shasum -a 256 -c build/releases/FantaLogcat-macos-arm64.zip.sha256`

Expected: tests pass, public checks pass, Release build is arm64, ZIP exists, and checksum verification prints `OK`.

- [ ] **Step 7: Commit release automation.**

```bash
git add Scripts/check-public-release.sh Scripts/test-public-release-check.sh .github/workflows/ci.yml Makefile .gitignore
git commit -m "ci: verify public release artifacts"
```

### Task 7: Final visual and repository verification

**Files:**
- Modify only files that fail the checks above; do not add unrelated features.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: evidence that the implementation meets the written design.

- [ ] **Step 1: Run formatting and repository hygiene checks.**

Run: `git diff --check && make check-public && git status --short`

Expected: no whitespace errors, public check passes, and only intentional implementation files are modified.

- [ ] **Step 2: Run the complete test and Release build suite from generated project files.**

Run: `make ci && make release && shasum -a 256 -c build/releases/FantaLogcat-macos-arm64.zip.sha256`

Expected: all tests and builds pass; checksum reports `OK`.

- [ ] **Step 3: Inspect the application at minimum size in both languages and appearances.**

Launch the Debug app and check 920×600 in Chinese/English and light/dark mode. Verify: Add is visually primary and easy to hit; saved keywords wrap; OR/AND reads as the next-condition control; empty-result Clear removes level chips, committed chips, and input; Close/Escape discard every setting; Save applies every setting; no control clips or overlaps.

- [ ] **Step 4: Inspect the built artifact.**

Run: `find build/releases/FantaLogcat.app -name 'TeamConfig.json' -o -name '*.dylib' | sort && lipo -archs build/releases/FantaLogcat.app/Contents/MacOS/FantaLogcat && codesign --verify --deep --strict build/releases/FantaLogcat.app`

Expected: no `TeamConfig.json`, architecture is `arm64`, and code-signature structure verifies.

- [ ] **Step 5: Review final diff against the design and commit any verification-only corrections.**

Confirm every requirement in `docs/superpowers/specs/2026-08-12-interaction-and-open-source-readiness-design.md` maps to an implementation or documented manual release step. If verification required corrections, commit only those corrections with `git commit -m "fix: complete release readiness verification"`.
