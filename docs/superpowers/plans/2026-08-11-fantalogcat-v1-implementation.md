# FantaLogcat 1.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a production-quality, local-only macOS app that lets a novice connect one Android device, select an app, inspect filtered Logcat output, and export safe diagnostic context without learning ADB commands.

**Architecture:** A SwiftUI application shell owns user-visible state while focused actors implement ADB control, device discovery, log parsing, bounded storage, filtering, configuration, and export. The high-volume log viewport uses AppKit virtualization; every core component is UI-independent and testable with a fake process runner and fixture streams.

**Tech Stack:** Xcode 26.6, Swift 6.3.3 in Swift 6 language mode, SwiftUI, AppKit, Foundation, CryptoKit, XCTest/XCUITest, XcodeGen 2.46.0, GitHub Actions.

## Global Constraints

- Deployment target is macOS 13.0; supported runtime architecture is arm64 only.
- The implementation toolchain is Xcode 26.6 with Swift 6 language mode. Full Xcode is required; Command Line Tools alone cannot build the app target.
- Runtime dependencies stay at zero for the first vertical slice. Add a package only when a task proves Foundation/AppKit cannot meet the requirement.
- All ADB invocations use an executable URL plus an argument array. Never invoke `/bin/sh`, `zsh`, `bash`, `sh -c`, or an interpolated command string.
- The public build never embeds Google Platform-Tools. It downloads a pinned official archive only after explicit user confirmation and verifies SHA-256 before execution.
- No telemetry, account, remote logging service, automatic history persistence, or device-log upload.
- One active device and one in-memory log session; multiple discovered devices require explicit selection.
- The default cache limits are 100,000 events and 128 MiB of message/raw-text bytes; neither protection can be disabled.
- User-visible strings are localized in Simplified Chinese and English. Status must never rely on color alone.
- Core code uses immutable `Sendable` value types and actor isolation. `@unchecked Sendable` requires a comment proving synchronization and a focused test.
- Every task follows red-green-refactor and ends with a commit. Run the full unit suite before each commit.
- The accepted design is `docs/superpowers/specs/2026-08-11-fantalogcat-design.md`; behavior changes require updating that document first.

## Prerequisite Gate

Before Task 1, run:

```bash
xcodebuild -version
swift --version
mint version
```

Expected: `Xcode 26.6`, Apple Swift `6.3.3`, and a working Mint installation. This workstation has Xcode 26.6 selected at `/Applications/Xcode.app/Contents/Developer`, its license accepted, and first-launch setup complete. If Mint is absent, install it with `brew install mint`. Installing software or switching Xcode requires explicit user authorization at execution time.

## Planned File Structure

```text
FantaLogcat/
├── project.yml                         # XcodeGen target/build definition
├── Mintfile                            # pins XcodeGen 2.46.0
├── Makefile                            # generate, test, build, package entry points
├── Config/
│   └── TeamConfig.example.json         # documented team input shape
├── FantaLogcatApp/
│   ├── Application/
│   │   ├── FantaLogcatApp.swift        # SwiftUI entry point
│   │   ├── AppModel.swift              # @MainActor UI orchestration
│   │   └── AppEnvironment.swift        # production dependency assembly
│   ├── ADB/
│   │   ├── ProcessRunner.swift         # safe Process/Pipe adapter
│   │   ├── ADBCommand.swift            # closed command vocabulary
│   │   ├── ADBRuntime.swift            # validated command execution
│   │   ├── ADBManifest.swift           # pinned download metadata
│   │   └── ADBInstaller.swift          # download, verify, install, rollback
│   ├── Devices/
│   │   ├── DeviceModels.swift          # device descriptors and states
│   │   └── DeviceService.swift         # discovery, pair, connect, reconnect
│   ├── Apps/
│   │   ├── AppModels.swift             # package metadata and preset overlay
│   │   └── AppCatalog.swift            # installed packages and PID resolution
│   ├── Logs/
│   │   ├── LogEvent.swift              # immutable structured event
│   │   ├── LogcatParser.swift           # streaming threadtime parser
│   │   ├── LogRingBuffer.swift          # dual-limit bounded storage
│   │   └── LogSession.swift             # capture lifecycle and UI batches
│   ├── Filters/
│   │   ├── FilterModels.swift           # serializable rules and presets
│   │   └── FilterEngine.swift           # compiled matching and context
│   ├── Configuration/
│   │   ├── ConfigurationModels.swift    # schema-versioned documents
│   │   ├── ConfigurationStore.swift     # three-layer merge and persistence
│   │   └── ConfigurationMigrator.swift  # pure version migrations
│   ├── Export/
│   │   ├── RedactionEngine.swift        # optional copy-only masking
│   │   ├── ExportModels.swift           # scope, format, preview
│   │   └── ExportService.swift          # TXT, JSONL, ZIP, AI Markdown
│   ├── Diagnostics/
│   │   └── AppDiagnostics.swift         # local tool diagnostics without log bodies
│   ├── Updates/
│   │   └── ReleaseChecker.swift        # GitHub release check; no self-replacement
│   ├── UI/
│   │   ├── RootView.swift               # top-level state routing
│   │   ├── OnboardingView.swift         # ADB preparation and device guidance
│   │   ├── MainLogView.swift            # toolbar, filter bar, status
│   │   ├── LogTableView.swift           # NSViewRepresentable bridge
│   │   ├── LogTableController.swift     # NSTableView virtualization/selection
│   │   ├── FilterEditorView.swift       # advanced rule editing
│   │   ├── ExportView.swift             # scope/redaction preview
│   │   └── SettingsView.swift           # limits, language, managed ADB
│   └── Resources/
│       ├── Assets.xcassets
│       ├── Localizable.xcstrings
│       ├── PublicDefaults.json
│       └── ADBManifest.json
├── FantaLogcatTests/
│   ├── Support/FakeProcessRunner.swift
│   ├── Support/FixtureFactory.swift
│   ├── ADB/
│   ├── Devices/
│   ├── Apps/
│   ├── Logs/
│   ├── Filters/
│   ├── Configuration/
│   ├── Export/
│   ├── UI/
│   └── Updates/
├── FantaLogcatUITests/
│   └── FirstRunFlowTests.swift
├── Scripts/
│   ├── prepare_team_config.sh           # validates and stages TeamDefaults.json
│   ├── verify_public_build.sh           # fails on embedded team data
│   ├── package_unsigned.sh              # arm64 ZIP/DMG and checksums
│   └── generate_sbom.sh                 # release dependency inventory
└── .github/workflows/
    ├── ci.yml
    └── release.yml
```

---

### Task 1: Reproducible macOS App Skeleton

**Files:**
- Create: `Mintfile`
- Create: `project.yml`
- Create: `Makefile`
- Create: `FantaLogcatApp/Application/FantaLogcatApp.swift`
- Create: `FantaLogcatApp/Application/AppModel.swift`
- Create: `FantaLogcatApp/Application/AppEnvironment.swift`
- Create: `FantaLogcatApp/UI/RootView.swift`
- Create: `FantaLogcatApp/Resources/Localizable.xcstrings`
- Create: `FantaLogcatTests/Application/AppModelTests.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `@MainActor final class AppModel: ObservableObject`, `enum AppPhase`, and `struct AppEnvironment` used by all UI tasks.
- Consumes: no production interfaces.

- [ ] **Step 1: Add the failing application-state test**

```swift
import XCTest
@testable import FantaLogcat

@MainActor
final class AppModelTests: XCTestCase {
    func testNewModelStartsInPreparingADBPhase() {
        let model = AppModel(environment: .test)
        XCTAssertEqual(model.phase, .preparingADB)
    }
}
```

- [ ] **Step 2: Add reproducible project metadata**

`Mintfile`:

```text
yonaskolb/XcodeGen@2.46.0
```

`project.yml`:

```yaml
name: FantaLogcat
options:
  deploymentTarget:
    macOS: "13.0"
  knownRegions: [en, zh-Hans]
settings:
  base:
    ARCHS: arm64
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: ""
    GENERATE_INFOPLIST_FILE: YES
    MACOSX_DEPLOYMENT_TARGET: "13.0"
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    CLANG_WARN_DOCUMENTATION_COMMENTS: YES
targets:
  FantaLogcat:
    type: application
    platform: macOS
    sources: [FantaLogcatApp]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.github.fantalogcat.FantaLogcat
        PRODUCT_NAME: FantaLogcat
        INFOPLIST_KEY_CFBundleDisplayName: FantaLogcat
        ENABLE_HARDENED_RUNTIME: YES
        ENABLE_APP_SANDBOX: NO
  FantaLogcatTests:
    type: bundle.unit-test
    platform: macOS
    sources: [FantaLogcatTests]
    dependencies:
      - target: FantaLogcat
  FantaLogcatUITests:
    type: bundle.ui-testing
    platform: macOS
    sources: [FantaLogcatUITests]
    dependencies:
      - target: FantaLogcat
schemes:
  FantaLogcat:
    build:
      targets:
        FantaLogcat: all
        FantaLogcatTests: [test]
    test:
      targets: [FantaLogcatTests]
```

- [ ] **Step 3: Generate the project and verify the test fails**

Run:

```bash
mint run xcodegen xcodegen generate
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/AppModelTests test
```

Expected: compilation fails because `AppModel`, `AppPhase`, and `.test` do not exist.

- [ ] **Step 4: Implement the minimal shell**

```swift
enum AppPhase: Equatable { case preparingADB, selectingDevice, selectingApp, viewingLogs }

struct AppEnvironment: Sendable {
    static let production = AppEnvironment()
    static let test = AppEnvironment()
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .preparingADB
    let environment: AppEnvironment
    init(environment: AppEnvironment) { self.environment = environment }
}
```

`RootView` switches on `phase` and renders localized descriptive text for each case. `FantaLogcatApp` owns `@StateObject var model` and injects it with `.environmentObject(model)`.

- [ ] **Step 5: Add build shortcuts and ignore generated artifacts**

`Makefile`:

```make
.PHONY: generate test build
DERIVED_DATA := build/DerivedData

generate:
	mint run xcodegen xcodegen generate

test: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' test

build: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' build
```

Add `FantaLogcat.xcodeproj/`, `.build/`, and `.mint/` to `.gitignore`; `project.yml` remains the source of truth.

- [ ] **Step 6: Verify the focused and full suites pass**

```bash
make generate
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/AppModelTests test
make test
```

Expected: both commands exit 0; the app builds for arm64 and the focused test reports one pass.

- [ ] **Step 7: Commit**

```bash
git add .gitignore Mintfile project.yml Makefile FantaLogcatApp FantaLogcatTests
git commit -m "build: create reproducible macOS app skeleton"
```

---

### Task 2: Structured Log Events and Streaming Parser

**Files:**
- Create: `FantaLogcatApp/Logs/LogEvent.swift`
- Create: `FantaLogcatApp/Logs/LogcatParser.swift`
- Create: `FantaLogcatTests/Logs/LogcatParserTests.swift`
- Create: `FantaLogcatTests/Support/FixtureFactory.swift`

**Interfaces:**
- Produces: `LogEvent`, `LogPriority`, `LogParseStatus`, and `actor LogcatParser` with `consume(_:receivedAt:)` and `finish(receivedAt:)`.
- Consumes: no earlier domain interfaces.

- [ ] **Step 1: Write parser tests for split UTF-8 and multiline events**

```swift
func testConsumesSplitUTF8AndMergesStackTrace() async throws {
    let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
    let bytes = Data("08-11 12:00:00.123  42  43 E Unity   : [NetworkManager]: 请求失败\n    at Game.Update()\n".utf8)
    let split = bytes.firstIndex(of: 0xE8)!
    let first = await parser.consume(Data(bytes[..<split]), receivedAt: FixtureFactory.referenceDate)
    let second = await parser.consume(Data(bytes[split...]), receivedAt: FixtureFactory.referenceDate)
    let tail = await parser.finish(receivedAt: FixtureFactory.referenceDate)

    XCTAssertTrue(first.isEmpty)
    XCTAssertEqual(second + tail, [
        LogEvent.fixture(id: 1, pid: 42, tid: 43, priority: .error,
                         androidTag: "Unity", businessTag: "NetworkManager",
                         message: "[NetworkManager]: 请求失败\n    at Game.Update()")
    ])
}

func testMalformedLineIsPreserved() async {
    let parser = LogcatParser(calendar: FixtureFactory.utcCalendar)
    _ = await parser.consume(Data("not threadtime\n".utf8), receivedAt: FixtureFactory.referenceDate)
    let events = await parser.finish(receivedAt: FixtureFactory.referenceDate)
    XCTAssertEqual(events.first?.parseStatus, .raw)
    XCTAssertEqual(events.first?.rawText, "not threadtime")
}
```

- [ ] **Step 2: Run the tests and confirm type failures**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/LogcatParserTests test
```

Expected: compilation fails for missing log-domain types.

- [ ] **Step 3: Define immutable log types**

```swift
enum LogPriority: String, Codable, Sendable, CaseIterable { case verbose, debug, info, warning, error, fatal, unknown }
enum LogParseStatus: String, Codable, Sendable { case complete, partial, raw }

struct LogEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UInt64
    let deviceTimestamp: Date?
    let receivedAt: Date
    let pid: Int32?
    let tid: Int32?
    let priority: LogPriority
    let androidTag: String?
    let businessTag: String?
    let message: String
    let rawText: String
    let parseStatus: LogParseStatus
    let packageName: String?
    let processName: String?
}
```

- [ ] **Step 4: Implement incremental parsing**

`LogcatParser` owns a byte remainder, decoded line remainder, next sequence ID, and pending event. `consume` decodes only complete UTF-8 prefixes, parses `MM-dd HH:mm:ss.SSS PID TID P TAG : message`, attaches indented/unmatched continuation lines to the pending event, and emits the prior event when the next header arrives. Extract `businessTag` only for `^[[]([^]]+)[]]:?` so ordinary brackets in the middle of a message are untouched.

- [ ] **Step 5: Add tests for every priority and year rollover**

Add table-driven cases mapping `V/D/I/W/E/F` and a December-to-January case using the injected calendar. Assert an empty `androidTag` becomes `nil`, not an empty string.

- [ ] **Step 6: Run focused and full tests, then commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/LogcatParserTests test
make test
git add FantaLogcatApp/Logs FantaLogcatTests/Logs FantaLogcatTests/Support
git commit -m "feat: parse structured logcat events"
```

Expected: parser cases pass and the full suite exits 0.

---

### Task 3: Dual-Limit In-Memory Log Buffer

**Files:**
- Create: `FantaLogcatApp/Logs/LogRingBuffer.swift`
- Create: `FantaLogcatTests/Logs/LogRingBufferTests.swift`

**Interfaces:**
- Produces: `CacheLimits`, `EvictionReport`, `LogSnapshot`, `SnapshotSelection`, and `actor LogRingBuffer`.
- Consumes: `[LogEvent]` from Task 2.

- [ ] **Step 1: Write failing count- and byte-limit tests**

```swift
func testEvictsOldestEventsAtEitherLimit() async {
    let buffer = LogRingBuffer(limits: .init(maxEvents: 2, maxTextBytes: 16))
    let report = await buffer.append([
        .fixture(id: 1, message: "1234"),
        .fixture(id: 2, message: "5678"),
        .fixture(id: 3, message: "90AB")
    ])
    let snapshot = await buffer.snapshot(.all)
    XCTAssertEqual(snapshot.events.map(\.id), [2, 3])
    XCTAssertEqual(report.evictedEvents, 1)
    XCTAssertEqual(snapshot.totalEvictedEvents, 1)
}
```

- [ ] **Step 2: Verify tests fail for missing buffer types**

Run the `LogRingBufferTests` target and expect compilation failure.

- [ ] **Step 3: Implement the actor and explicit accounting**

```swift
struct CacheLimits: Sendable, Equatable {
    static let `default` = CacheLimits(maxEvents: 100_000, maxTextBytes: 128 * 1_024 * 1_024)
    let maxEvents: Int
    let maxTextBytes: Int
}

struct EvictionReport: Sendable, Equatable {
    let evictedEvents: Int
    let evictedTextBytes: Int
    let newestEventExceedsByteLimit: Bool
}

enum SnapshotSelection: Sendable {
    case all
    case ids(Set<UInt64>)
    case receivedTime(ClosedRange<Date>)
}

struct LogSnapshot: Sendable {
    let events: [LogEvent]
    let totalEvictedEvents: Int
    let newestEventExceedsByteLimit: Bool
}

actor LogRingBuffer {
    private let limits: CacheLimits
    private var events: [LogEvent] = []
    private var textBytes = 0
    private var totalEvictedEvents = 0

    init(limits: CacheLimits) { self.limits = limits }

    func append(_ incoming: [LogEvent]) -> EvictionReport {
        events.append(contentsOf: incoming)
        textBytes += incoming.reduce(0) { $0 + Self.textBytes(of: $1) }
        var evictedEvents = 0
        var evictedBytes = 0
        while events.count > limits.maxEvents || (textBytes > limits.maxTextBytes && events.count > 1) {
            let removed = events.removeFirst()
            let bytes = Self.textBytes(of: removed)
            textBytes -= bytes
            evictedEvents += 1
            evictedBytes += bytes
        }
        totalEvictedEvents += evictedEvents
        return EvictionReport(evictedEvents: evictedEvents,
                              evictedTextBytes: evictedBytes,
                              newestEventExceedsByteLimit: textBytes > limits.maxTextBytes)
    }

    func snapshot(_ selection: SnapshotSelection) -> LogSnapshot {
        let selected: [LogEvent]
        switch selection {
        case .all: selected = events
        case .ids(let ids): selected = events.filter { ids.contains($0.id) }
        case .receivedTime(let range): selected = events.filter { range.contains($0.receivedAt) }
        }
        return LogSnapshot(events: selected,
                           totalEvictedEvents: totalEvictedEvents,
                           newestEventExceedsByteLimit: textBytes > limits.maxTextBytes)
    }

    func clear() {
        events.removeAll(keepingCapacity: true)
        textBytes = 0
        totalEvictedEvents = 0
    }

    private static func textBytes(of event: LogEvent) -> Int {
        event.message.utf8.count + event.rawText.utf8.count
    }
}
```

Count UTF-8 bytes of both `message` and `rawText`; document that object overhead is not part of the deterministic text limit.

- [ ] **Step 4: Test oversized single events and snapshot consistency**

Assert a single event larger than `maxTextBytes` is retained as the newest event while all older entries are evicted and the snapshot records `isOverByteLimitBecauseNewestEventIsOversized = true`. Assert snapshots do not change after later appends.

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/LogRingBufferTests test
make test
git add FantaLogcatApp/Logs/LogRingBuffer.swift FantaLogcatTests/Logs/LogRingBufferTests.swift
git commit -m "feat: add bounded in-memory log storage"
```

---

### Task 4: Safe Process Runner and Closed ADB Command Vocabulary

**Files:**
- Create: `FantaLogcatApp/ADB/ProcessRunner.swift`
- Create: `FantaLogcatApp/ADB/ADBCommand.swift`
- Create: `FantaLogcatApp/ADB/ADBRuntime.swift`
- Create: `FantaLogcatTests/Support/FakeProcessRunner.swift`
- Create: `FantaLogcatTests/ADB/ADBRuntimeTests.swift`

**Interfaces:**
- Produces: `ProcessRunning`, `ProcessResult`, `ProcessOutput`, `ADBCommand`, `ADBRuntimeProtocol`, and `ADBRuntime`.
- Consumes: an already installed ADB executable URL; installation is Task 5.

- [ ] **Step 1: Write a failing command-argument test**

```swift
func testDevicesUsesArgumentArrayAndRejectsControlCharacters() async throws {
    let runner = FakeProcessRunner(result: .success(stdout: "List of devices attached\n"))
    let runtime = ADBRuntime(executableURL: URL(fileURLWithPath: "/managed/adb"), runner: runner)
    _ = try await runtime.run(.devices(longFormat: true), timeout: .seconds(5))
    XCTAssertEqual(runner.lastInvocation?.arguments, ["devices", "-l"])
    XCTAssertThrowsError(try ADBEndpoint(host: "127.0.0.1;open /tmp/x", port: 5555))
}
```

- [ ] **Step 2: Run the test and verify missing-interface failure**

Run `ADBRuntimeTests`; expect compilation failure.

- [ ] **Step 3: Implement process interfaces and cancellation**

```swift
protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessResult
    func stream(executable: URL, arguments: [String]) throws -> AsyncThrowingStream<ProcessOutput, Error>
}

enum ProcessOutput: Sendable, Equatable { case stdout(Data), stderr(Data), exited(Int32) }
struct ProcessResult: Sendable, Equatable { let exitCode: Int32; let stdout: Data; let stderr: Data }
```

The production runner uses `Process.executableURL` and `arguments`, drains stdout and stderr concurrently, terminates on task cancellation or timeout, and never routes through a shell.

- [ ] **Step 4: Implement a closed `ADBCommand` enum**

Include only `version`, `devices`, `pair`, `connect`, `disconnect`, `listThirdPartyPackages`, `resolvePIDs`, `startApplication`, and `logcatThreadtime`. Define throwing value types `ADBEndpoint`, `ADBDeviceSerial`, `AndroidPackageName`, and `ADBPairingCode`; enum cases accept only those validated types. `ADBRuntime` converts each case to arguments internally and treats a nonzero exit as `ADBError.commandFailed` with a length-limited stderr summary.

- [ ] **Step 5: Test timeout, cancellation, stderr, and injection strings**

Use the fake runner to assert timeout propagation and redacted errors. Add a production-runner test executable fixture that writes alternating stdout/stderr chunks and waits for termination; assert both pipes are drained and cancellation ends the process.

- [ ] **Step 6: Run tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/ADBRuntimeTests test
make test
git add FantaLogcatApp/ADB FantaLogcatTests/ADB FantaLogcatTests/Support/FakeProcessRunner.swift
git commit -m "feat: add safe adb command runtime"
```

---

### Task 5: Managed ADB Download, Verification, and Rollback

**Files:**
- Create: `FantaLogcatApp/ADB/ADBManifest.swift`
- Create: `FantaLogcatApp/ADB/ADBInstaller.swift`
- Create: `FantaLogcatApp/Resources/ADBManifest.json`
- Create: `FantaLogcatTests/ADB/ADBInstallerTests.swift`
- Modify: `FantaLogcatApp/Application/AppEnvironment.swift`

**Interfaces:**
- Produces: `ADBManifest`, `ADBInstallationState`, `DownloadClient`, `ArchiveExtracting`, and `actor ADBInstaller` with `state()`, `install(acceptingLicense:)`, and `rollback()`.
- Consumes: `ADBRuntime` version command from Task 4 after installation.

- [ ] **Step 1: Write failing checksum and atomic-install tests**

```swift
func testChecksumMismatchNeverReplacesWorkingInstallation() async throws {
    let files = InMemoryFileSystem(existingVersion: "36.0.2")
    let installer = ADBInstaller(manifest: .fixture(sha256: String(repeating: "0", count: 64)),
                                 downloader: .fixture(bytes: Data("bad".utf8)),
                                 extractor: .fixture(), files: files)
    do {
        try await installer.install(acceptingLicense: true)
        XCTFail("Expected checksumMismatch")
    } catch ADBInstallerError.checksumMismatch {
        // Expected path.
    }
    XCTAssertEqual(files.activeVersion, "36.0.2")
    XCTAssertFalse(files.containsPartialInstall)
}
```

- [ ] **Step 2: Verify the test fails before implementation**

Run `ADBInstallerTests`; expect missing-type compilation errors.

- [ ] **Step 3: Define a versioned manifest and strict decoder**

```swift
struct ADBManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let platformToolsVersion: String
    let downloadURL: URL
    let archiveBytes: Int
    let sha256: String
    let licenseURL: URL
    let verifiedAt: Date
}
```

Decode `verifiedAt` with `JSONDecoder.DateDecodingStrategy.iso8601`. Reject non-HTTPS URLs, non-Google download hosts, non-64-character lowercase hex hashes, unsupported schema versions, and archives above the declared size plus 1 percent transport tolerance.

- [ ] **Step 4: Implement safe installation**

Download to a unique temporary directory, stream SHA-256 with CryptoKit, reject symlinks/absolute paths/`..`, extract only required managed files, verify `adb version`, then atomically rename `candidate` to `versions/<version>` and update an `active.json` pointer. Preserve one prior verified version.

- [ ] **Step 5: Cover license refusal, interrupted download, malicious archive, and rollback**

Assert `acceptingLicense: false` performs no network request. Assert each failure deletes the candidate, keeps the active installation, and returns a localized error code rather than raw paths.

- [ ] **Step 6: Add the verified official manifest**

Use the stable 37.0.0 Darwin archive verified on 2026-08-11:

```json
{
  "schemaVersion": 1,
  "platformToolsVersion": "37.0.0",
  "downloadURL": "https://dl.google.com/android/repository/platform-tools_r37.0.0-darwin.zip",
  "archiveBytes": 16442240,
  "sha256": "094a1395683c509fd4d48667da0d8b5ef4d42b2abfcd29f2e8149e2f989357c7",
  "licenseURL": "https://developer.android.com/studio/terms",
  "verifiedAt": "2026-08-11"
}
```

The archive's `adb` and `lib64/libc++.dylib` are universal Mach-O binaries containing arm64 slices. Production extraction retains `adb`, `lib64/libc++.dylib`, `source.properties`, and `NOTICE.txt`; it excludes unrelated tools.

- [ ] **Step 7: Run tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/ADBInstallerTests test
make test
git add FantaLogcatApp/ADB FantaLogcatApp/Resources/ADBManifest.json FantaLogcatApp/Application/AppEnvironment.swift FantaLogcatTests/ADB
git commit -m "feat: manage verified adb installations"
```

---

### Task 6: Device Discovery and Beginner-Friendly Connection State Machine

**Files:**
- Create: `FantaLogcatApp/Devices/DeviceModels.swift`
- Create: `FantaLogcatApp/Devices/DeviceService.swift`
- Create: `FantaLogcatTests/Devices/DeviceServiceTests.swift`
- Create: `FantaLogcatApp/UI/OnboardingView.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`
- Modify: `FantaLogcatApp/UI/RootView.swift`

**Interfaces:**
- Produces: `DeviceDescriptor`, `DeviceConnectionState`, `DeviceServiceProtocol`, `actor DeviceService`, and `AsyncStream<DeviceConnectionState> states`.
- Consumes: `ADBRuntimeProtocol` from Task 4 and `ADBInstallationState` from Task 5.

- [ ] **Step 1: Write state-transition tests**

```swift
func testUnauthorizedDeviceProducesActionableState() async throws {
    let adb = FakeADBRuntime(devicesOutput: "ABC123 unauthorized usb:1-1 product:x model:Pixel_8 device:x")
    let service = DeviceService(adb: adb, clock: .immediate)
    let state = try await service.refresh()
    XCTAssertEqual(state, .authorizationRequired(.init(serial: "ABC123", displayName: "Pixel 8")))
}

func testMultipleOnlineDevicesRequireExplicitSelection() async throws {
    let service = DeviceService(adb: .twoOnlineDevices, clock: .immediate)
    guard case .selectionRequired(let devices) = try await service.refresh() else {
        return XCTFail("Expected selectionRequired")
    }
    XCTAssertEqual(devices.count, 2)
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run `DeviceServiceTests`; expect missing models and service.

- [ ] **Step 3: Implement the state model and parser**

```swift
enum DeviceConnectionState: Sendable, Equatable {
    case noDevice
    case authorizationRequired(DeviceDescriptor)
    case selectionRequired([DeviceDescriptor])
    case connecting(DeviceDescriptor)
    case connected(DeviceDescriptor)
    case offline(DeviceDescriptor)
    case failed(DeviceFailure)
}
```

Parse `adb devices -l` without depending on column spacing. Device display name uses the `model:` field with underscores converted to spaces; serial remains hidden from normal UI.

- [ ] **Step 4: Implement pair, connect, selection, and reconnect**

Validate pairing code as six ASCII digits and ports as 1...65535. Reconnect after 1, 2, 5, then 10 seconds using an injected clock; stop retries immediately when the user selects another device or cancels.

- [ ] **Step 5: Build onboarding UI with accessibility identifiers**

Render natural-language states with buttons `prepareADBButton`, `usbHelpButton`, `wirelessPairButton`, `retryConnectionButton`, and `deviceChoice.<serialHash>`. Show pairing address and connection address as separate labeled fields. Never expose ADB command text in the normal flow.

- [ ] **Step 6: Run unit/UI smoke tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/DeviceServiceTests test
make test
git add FantaLogcatApp/Devices FantaLogcatApp/UI/OnboardingView.swift FantaLogcatApp/UI/RootView.swift FantaLogcatApp/Application/AppModel.swift FantaLogcatTests/Devices
git commit -m "feat: guide device connection and recovery"
```

---

### Task 7: Application Catalog and PID Tracking

**Files:**
- Create: `FantaLogcatApp/Apps/AppModels.swift`
- Create: `FantaLogcatApp/Apps/AppCatalog.swift`
- Create: `FantaLogcatTests/Apps/AppCatalogTests.swift`
- Modify: `FantaLogcatApp/ADB/ADBCommand.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`

**Interfaces:**
- Produces: `AppPreset`, `AppDescriptor`, `AppPresentation`, `ProcessDescriptor`, `AppCatalogProtocol`, and `actor AppCatalog`.
- Consumes: selected `DeviceDescriptor`, `ADBRuntimeProtocol`, and application presets supplied later by `ConfigurationStore` through `[AppPreset]`.

- [ ] **Step 1: Write catalog merge and child-process tests**

```swift
func testConfiguredAppGetsFriendlyPresentationAndUnknownAppDoesNotInventMetadata() async throws {
    let catalog = AppCatalog(adb: .packages(["com.game.tile", "com.unknown"]), presets: [
        .init(id: "team.tile", packageName: "com.game.tile", displayName: "Tile Match",
              symbolName: "gamecontroller.fill")
    ])
    let apps = try await catalog.listApps(on: .fixture)
    XCTAssertEqual(apps[0].presentation.displayName, "Tile Match")
    XCTAssertEqual(apps[1].presentation.displayName, "com.unknown")
    XCTAssertEqual(apps[1].presentation.icon, .generic)
}

func testPIDResolutionIncludesPackageChildProcesses() async throws {
    let processes = try await AppCatalog(adb: .processes("42 com.game.tile\n43 com.game.tile:ads\n44 com.other"))
        .resolveProcesses(packageName: "com.game.tile", on: .fixture)
    XCTAssertEqual(processes.map(\.pid), [42, 43])
}
```

- [ ] **Step 2: Verify failures, then define models**

`AppDescriptor` is `Identifiable`, `Sendable`, and keyed by package name. `AppPreset` contains stable ID, package name, display name, optional SF Symbol name, favorite order, and group; it does not reference arbitrary filesystem icons. `AppPresentation` records `.preset` or `.generic` provenance so the UI never implies device-derived metadata.

- [ ] **Step 3: Implement package listing and process resolution**

Use the closed commands `pm list packages -3` and `ps -A -o PID,NAME` with compatibility parsing for toolbox/toybox spacing. Package validation is `^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$`. Sort favorites first, then configured display name, then package name.

- [ ] **Step 4: Implement the standard launch attempt**

Add a typed `startApplication` command that invokes `monkey -p <package> -c android.intent.category.LAUNCHER 1`. Treat “no activities found” as a user-facing `notLaunchable` result, not a generic command failure.

- [ ] **Step 5: Run tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/AppCatalogTests test
make test
git add FantaLogcatApp/Apps FantaLogcatApp/ADB/ADBCommand.swift FantaLogcatApp/Application/AppModel.swift FantaLogcatTests/Apps
git commit -m "feat: discover apps and track their processes"
```

---

### Task 8: Live Log Session, Reconnection, and Batched Updates

**Files:**
- Create: `FantaLogcatApp/Logs/LogSession.swift`
- Create: `FantaLogcatTests/Logs/LogSessionTests.swift`
- Modify: `FantaLogcatApp/Logs/LogEvent.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`

**Interfaces:**
- Produces: `LogSessionProtocol`, `LogSessionUpdate`, `LogSessionStatus`, and `actor LogSession` with `start(device:)`, `stop()`, `clear()`, `snapshot(_:)`, and `updates`.
- Consumes: `ADBRuntimeProtocol`, `LogcatParser`, `LogRingBuffer`, `AppCatalogProtocol`, and selected package name.

- [ ] **Step 1: Write lifecycle and batching tests**

```swift
func testPausePresentationDoesNotStopCapture() async throws {
    let session = LogSession.fixture(lines: 300, uiBatchInterval: .milliseconds(50))
    try await session.start(device: .fixture)
    await session.setPresentationPaused(true)
    await session.fixtureClock.advance(by: .seconds(1))
    XCTAssertEqual(await session.snapshot(.all).events.count, 300)
    XCTAssertFalse(await session.fixtureADB.wasStreamCancelled)
}

func testClearDoesNotExecuteDeviceLogcatClear() async throws {
    let session = LogSession.fixture(lines: 10)
    let commandsBefore = await session.fixtureADB.commands
    await session.clear()
    XCTAssertEqual(await session.fixtureADB.commands, commandsBefore)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run `LogSessionTests`; expect missing session interfaces.

- [ ] **Step 3: Implement capture lifecycle**

Start one `logcat -v threadtime` stream for the selected serial, feed bytes to `LogcatParser`, enrich emitted events with the latest PID-to-package map, and append batches to `LogRingBuffer`. On stream exit while desired state is running, restart after 1, 2, 5, and 10 seconds. `stop()` cancels stream, retry, PID refresh, and UI batch tasks.

- [ ] **Step 4: Implement bounded UI updates**

```swift
enum LogSessionUpdate: Sendable, Equatable {
    case appended(ids: [UInt64], totalCount: Int)
    case evicted(EvictionReport)
    case status(LogSessionStatus)
    case cleared
}
```

Coalesce append notifications for 50–100 ms or 500 IDs, whichever comes first. Presentation pause suppresses `.appended` notifications while retaining a pending count; resume emits one catch-up update.

- [ ] **Step 5: Add flood, reconnect, and cancellation tests**

Feed 20,000 fixture lines in fragmented chunks, assert ordered IDs, cache limits, bounded update count, and no unstructured task survives `stop()`.

- [ ] **Step 6: Run tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/LogSessionTests test
make test
git add FantaLogcatApp/Logs FantaLogcatApp/Application/AppModel.swift FantaLogcatTests/Logs
git commit -m "feat: stream bounded live log sessions"
```

---

### Task 9: Versioned Configuration and Compiled Filters

**Files:**
- Create: `FantaLogcatApp/Filters/FilterModels.swift`
- Create: `FantaLogcatApp/Filters/FilterEngine.swift`
- Create: `FantaLogcatApp/Configuration/ConfigurationModels.swift`
- Create: `FantaLogcatApp/Configuration/ConfigurationMigrator.swift`
- Create: `FantaLogcatApp/Configuration/ConfigurationStore.swift`
- Create: `FantaLogcatApp/Resources/PublicDefaults.json`
- Create: `Config/TeamConfig.example.json`
- Create: `FantaLogcatTests/Filters/FilterEngineTests.swift`
- Create: `FantaLogcatTests/Configuration/ConfigurationStoreTests.swift`

**Interfaces:**
- Produces: `FilterRule`, `FilterScope`, `CompiledFilter`, `FilterEngine`, `ConfigurationDocument`, `MergedConfiguration`, and `ConfigurationStore`.
- Consumes: `LogEvent` and `AppPreset`.

- [ ] **Step 1: Write filter semantics tests**

```swift
func testRuleCombinesScopeLevelIncludeExcludeAndBusinessTag() throws {
    let rule = FilterRule.fixture(scope: .package("com.game"),
                                  priorities: [.warning, .error, .fatal],
                                  include: ["request"], exclude: ["heartbeat"],
                                  businessTags: ["NetworkManager"])
    let filter = try FilterEngine.compile(rule)
    XCTAssertTrue(filter.matches(.fixture(priority: .error, businessTag: "NetworkManager",
                                          message: "request failed", packageName: "com.game")))
    XCTAssertFalse(filter.matches(.fixture(priority: .error, businessTag: "NetworkManager",
                                           message: "heartbeat request", packageName: "com.game")))
}
```

- [ ] **Step 2: Write three-layer merge tests**

```swift
func testUserLayerOverridesTeamAndCanHidePublicEntry() throws {
    let merged = try ConfigurationStore.merge(public: .publicFixture,
                                              team: .teamFixture,
                                              user: .userFixture)
    XCTAssertEqual(merged.appsByID["team.tile"]?.isFavorite, true)
    XCTAssertNil(merged.filtersByID["public.network"])
    XCTAssertEqual(merged.provenance["team.tile"], .userOverride)
}
```

- [ ] **Step 3: Verify both test classes fail**

Run focused filter and configuration tests; expect missing-domain compilation failures.

- [ ] **Step 4: Implement serializable rules and safe compilation**

`FilterRule` includes ID, localized name keys, scope, `Set<LogPriority> priorities`, Android Tags, business Tags, include/exclude terms, optional regex, case sensitivity, and context window. Reject regex strings over 1,024 UTF-8 bytes. Compile once with `NSRegularExpression`; apply in cancellable batches of 1,000 events off the main actor.

- [ ] **Step 5: Implement schema version 1 and deterministic merge**

Decode `ConfigurationDocument(schemaVersion: 1, apps:filters:redactionRules:)` with caps of 1,000 apps, 1,000 filters, 100 redaction rules, and 4,096 bytes per user string. `MergedConfiguration` exposes `appsByID`, `filtersByID`, `redactionRulesByID`, and `provenance` dictionaries keyed by stable namespaced ID. Merge with precedence user > team > public. User tombstones hide lower-layer entries without deleting package resources.

- [ ] **Step 6: Add import preview and atomic user persistence**

Return `ImportPreview(added:overridden:skipped:conflicts:)`; only mutate `UserConfig.json` after explicit apply. Write a temporary file, fsync, then replace. A document above supported `schemaVersion` returns `.newerSchema` and leaves the existing file byte-identical.

- [ ] **Step 7: Add public and team-example presets**

Public JSON contains current-app, Unity, warning/error, crash/ANR, and generic network presets. Team example demonstrates `NetworkManager`, `NetworkDelegate`, `IAA`, `EventTracker`, `TaskManager`, `RewardLogger`, and `Withdraw` without real company package names.

- [ ] **Step 8: Run tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/FilterEngineTests -only-testing:FantaLogcatTests/ConfigurationStoreTests test
make test
git add FantaLogcatApp/Filters FantaLogcatApp/Configuration FantaLogcatApp/Resources/PublicDefaults.json Config FantaLogcatTests/Filters FantaLogcatTests/Configuration
git commit -m "feat: add layered presets and safe filtering"
```

---

### Task 10: Virtualized Main Log Interface

**Files:**
- Create: `FantaLogcatApp/UI/MainLogView.swift`
- Create: `FantaLogcatApp/UI/LogTableView.swift`
- Create: `FantaLogcatApp/UI/LogTableController.swift`
- Create: `FantaLogcatApp/UI/FilterEditorView.swift`
- Create: `FantaLogcatTests/UI/LogTableControllerTests.swift`
- Modify: `FantaLogcatApp/UI/RootView.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`

**Interfaces:**
- Produces: `LogTableDataSource`, `LogSelection`, and `LogTableController` operations `apply(diff:)`, `scrollToBottom()`, and `setFollowing(_:)`.
- Consumes: `LogSessionUpdate`, `LogSnapshot`, `CompiledFilter`, device/app state, and merged presets.

- [ ] **Step 1: Write controller tests for follow and selection preservation**

```swift
func testAppendingWhileScrolledUpPreservesSelectionAndShowsPendingCount() {
    let controller = LogTableController.testInstance(ids: [1, 2, 3])
    controller.userDidScrollAwayFromBottom()
    controller.apply(diff: .append([4, 5]))
    XCTAssertEqual(controller.pendingNewCount, 2)
    XCTAssertFalse(controller.isFollowingBottom)
    XCTAssertEqual(controller.visibleAnchorID, 1)
}
```

- [ ] **Step 2: Run tests and confirm failure**

Run `LogTableControllerTests`; expect missing controller types.

- [ ] **Step 3: Implement the AppKit table bridge**

Use view-based `NSTableView` with reusable cells and no per-event SwiftUI view. Columns are time, level, source, and message. The data source stores visible event IDs plus a snapshot lookup closure. Apply appended/removed row indexes in batches; preserve selected IDs and scroll anchor across filter diffs.

- [ ] **Step 4: Implement beginner-first main UI**

Top bar: active device, app picker, pause, clear, export. Filter bar: all, warning, error, business presets, chips, search, advanced disclosure. Status: visible/total counts, oldest retained time, evicted count, connection state, and “new N” button. Unknown apps display a generic icon and package name; configured apps display supplied presentation metadata.

- [ ] **Step 5: Implement multiline expansion and keyboard behavior**

Single click selects, double click toggles expanded height, `⌘F` focuses search, `⌘K` clears the in-app session, `Space` pauses only outside text inputs, `⌘L` restores bottom following, and `⌘E` opens export. VoiceOver reads time, level, source, and complete message in that order.

- [ ] **Step 6: Add a 100,000-row UI performance test**

Measure applying a 500-ID batch to a 100,000-ID data source and assert no eager cell creation beyond visible rows plus AppKit reuse tolerance. Record the baseline in the test attachment; fail if median apply time regresses by more than 25 percent from the committed threshold.

- [ ] **Step 7: Run tests and commit**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/LogTableControllerTests test
make test
git add FantaLogcatApp/UI FantaLogcatApp/Application/AppModel.swift FantaLogcatTests/UI
git commit -m "feat: add virtualized log viewing workflow"
```

---

### Task 11: Export, AI Context, and Optional Redaction

**Files:**
- Create: `FantaLogcatApp/Export/RedactionEngine.swift`
- Create: `FantaLogcatApp/Export/ExportModels.swift`
- Create: `FantaLogcatApp/Export/ExportService.swift`
- Create: `FantaLogcatApp/UI/ExportView.swift`
- Create: `FantaLogcatTests/Export/RedactionEngineTests.swift`
- Create: `FantaLogcatTests/Export/ExportServiceTests.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`

**Interfaces:**
- Produces: `ExportScope`, `ExportFormat`, `ExportRequest`, `ExportPreview`, `RedactionRule`, `RedactionEngine`, and `ExportService`.
- Consumes: immutable `LogSnapshot`, current filter description, selected IDs, environment summary, and user redaction rules.

- [ ] **Step 1: Write redaction copy-safety tests**

```swift
func testRedactionChangesExportCopyWithoutMutatingSnapshot() throws {
    let snapshot = LogSnapshot.fixture(message: "token=secret@example.com")
    let output = try RedactionEngine(rules: [.email]).redact(snapshot)
    XCTAssertEqual(output.events.first?.message, "token=<email>")
    XCTAssertEqual(snapshot.events.first?.message, "token=secret@example.com")
    XCTAssertEqual(output.hitCount, 1)
}
```

- [ ] **Step 2: Write AI-budget and range tests**

```swift
func testAIExportReportsOmittedCountAndKeepsErrorContext() async throws {
    let service = ExportService(characterBudget: 2_000)
    let result = try await service.render(.fixture(format: .aiMarkdown, scope: .all,
                                                   events: FixtureFactory.mixedPriorityEvents(500)))
    XCTAssertTrue(result.text.contains("省略事件数:"))
    XCTAssertTrue(result.text.contains("NullReferenceException"))
    XCTAssertLessThanOrEqual(result.text.count, 2_000)
}
```

- [ ] **Step 3: Verify focused tests fail**

Run both Export test classes; expect missing export types.

- [ ] **Step 4: Implement scope and preview**

Support `.all`, `.filtered(ids:)`, `.selected(ids:)`, `.timeRange(ClosedRange<Date>)`, and `.context(anchorID:before:after:)`. Preview reports event count, first/last time, estimated bytes, prior evictions, and redaction hit count. Reject empty and fully evicted ranges with a specific explanation.

- [ ] **Step 5: Implement TXT, JSONL, and AI Markdown**

TXT has a stable metadata header and threadtime-like lines. JSONL starts directly with one versioned event object per line. AI Markdown contains user question fields, sanitized environment, active filters, omission policy, and fenced logs. Selection prioritizes fatal/error, then warning, then context, while preserving chronological output order.

- [ ] **Step 6: Implement ZIP without adding an archive dependency**

Create a staging directory with `logs.jsonl`, `summary.json`, `filters.json`, and `README.txt`, then invoke `/usr/bin/ditto` through `ProcessRunning` with a fixed argument array `[-c, -k, --sequesterRsrc, --keepParent, staging, destination]`. Validate both URLs are app-created/user-selected, disallow overwrite without confirmation, and delete staging in `defer`.

- [ ] **Step 7: Implement atomic output and export UI**

Write TXT/JSONL to a sibling temporary file, synchronize, then replace the selected destination. `ExportView` requires scope, format, optional redaction, preview refresh, and explicit export/copy. It displays a warning that redaction cannot guarantee removal of every secret.

- [ ] **Step 8: Test disk failure and commit**

Inject a file writer that fails with no-space and permission errors. Assert no partial destination replaces an existing file and the in-memory session remains available.

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatTests/RedactionEngineTests -only-testing:FantaLogcatTests/ExportServiceTests test
make test
git add FantaLogcatApp/Export FantaLogcatApp/UI/ExportView.swift FantaLogcatApp/Application/AppModel.swift FantaLogcatTests/Export
git commit -m "feat: export safe diagnostic context"
```

---

### Task 12: Localization, Diagnostics, Security Checks, and Release Pipeline

**Files:**
- Create: `FantaLogcatApp/Diagnostics/AppDiagnostics.swift`
- Create: `FantaLogcatApp/Updates/ReleaseChecker.swift`
- Create: `FantaLogcatApp/UI/SettingsView.swift`
- Modify: `FantaLogcatApp/Resources/Localizable.xcstrings`
- Create: `FantaLogcatUITests/FirstRunFlowTests.swift`
- Create: `FantaLogcatTests/Updates/ReleaseCheckerTests.swift`
- Create: `Scripts/prepare_team_config.sh`
- Create: `Scripts/verify_public_build.sh`
- Create: `Scripts/package_unsigned.sh`
- Create: `Scripts/generate_sbom.sh`
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Create: `LICENSE`
- Create: `NOTICE`
- Create: `SECURITY.md`
- Create: `CONTRIBUTING.md`
- Create: `README.md`
- Modify: `project.yml`

**Interfaces:**
- Produces: `ReleaseChecking`, `ReleaseStatus`, release artifacts, and contributor/security documentation.
- Consumes: the complete application from Tasks 1–11.

- [ ] **Step 1: Add an end-to-end UI test using launch-injected fakes**

```swift
func testFirstRunConnectSelectFilterAndExport() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--fixture", "happy-path"]
    app.launch()
    app.buttons["prepareADBButton"].click()
    app.buttons["deviceChoice.fixture"].click()
    app.popUpButtons["appPicker"].click()
    app.menuItems["Tile Match"].click()
    XCTAssertTrue(app.tables["logTable"].waitForExistence(timeout: 3))
    app.buttons["filter.error"].click()
    app.buttons["exportButton"].click()
    XCTAssertEqual(app.staticTexts["exportPreviewCount"].value as? String, "1")
}
```

- [ ] **Step 2: Run the UI test and verify it fails on missing fixture assembly**

```bash
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -destination 'platform=macOS,arch=arm64' -only-testing:FantaLogcatUITests/FirstRunFlowTests test
```

Expected: failure because `--ui-testing` dependency assembly and stable accessibility identifiers are incomplete.

- [ ] **Step 3: Add deterministic UI-test dependency assembly**

`AppEnvironment` recognizes `--ui-testing` only in Debug builds, loads fixture services without invoking ADB or network, and covers happy path, unauthorized, offline, no-app, cache-evicted, and export-failure states. Release builds ignore these arguments.

- [ ] **Step 4: Complete localization and accessibility**

Populate every catalog entry with `en` and `zh-Hans`; enable the build setting that treats missing localizations as warnings and make warnings fail CI. Run UI tests in both languages and light/dark appearances. Add VoiceOver labels for device state, log rows, filter chips, eviction status, and export preview.

- [ ] **Step 5: Implement privacy-preserving application diagnostics**

`AppDiagnostics` records timestamp, subsystem, event code, and length-limited metadata allowlisted per event. Its API accepts no `LogEvent` or raw command-output type. Keep seven rolling local files capped at 1 MiB each; diagnostics export requires a separate explicit checkbox.

- [ ] **Step 6: Add safe GitHub release checks and complete settings**

Define `ReleaseChecking.check(currentVersion:) async throws -> ReleaseStatus` and implement it with a fixed GitHub Releases API URL, HTTPS-only redirect policy, five-second timeout, and a non-secret User-Agent. Parse semantic versions without executing downloaded content. Automatic checks run at most once per 24 hours; the UI only offers “打开下载页面”. Unit tests cover newer, equal, prerelease, malformed, offline, timeout, and non-HTTPS release URL responses. `SettingsView` exposes cache limits within 10,000...500,000 events and 32...512 MiB, language, managed/system ADB selection, configuration import/export preview, and manual update check.

- [ ] **Step 7: Add team/public build isolation scripts**

`prepare_team_config.sh <input-json> <staging-resources>` runs `/usr/bin/plutil -lint`, reads `schemaVersion` with `/usr/bin/plutil -extract schemaVersion raw`, requires the value `1`, rejects an input inside the public repository, and copies it to `<staging-resources>/TeamDefaults.json`. The internal CI job runs `ConfigurationStoreTests` against that staged file before packaging. `verify_public_build.sh <app-bundle>` requires `FANTALOGCAT_DISTRIBUTION=public`, fails if any `TeamDefaults.json` exists, and optionally scans every bundle string against an external `FANTALOGCAT_DENYLIST_PATH` without committing internal terms. Add shell fixture tests for accepted public bundles, embedded team resources, missing distribution mode, and denylist hits.

- [ ] **Step 8: Add unsigned packaging and release verification**

`package_unsigned.sh` verifies arm64 with `lipo -info`, applies ad-hoc signing to nested executables then the app, creates ZIP and DMG, invokes `generate_sbom.sh`, and emits SHA-256 plus NOTICE/SBOM artifacts. It never calls `xattr -d` or disables Gatekeeper. `release.yml` uploads artifacts only after unit, UI, security-script, public-config, and `spctl` expectation checks pass.

- [ ] **Step 9: Add CI performance and soak jobs**

`ci.yml` validates `project.yml`, regenerates the ignored Xcode project from a clean directory, builds with warnings as errors, runs unit/UI tests, a 5,000 events/sec sustained parser benchmark, a 20,000 events/sec burst benchmark, and a bounded 30-minute fake-ADB soak. Store `.xcresult` and memory metrics when a job fails.

- [ ] **Step 10: Add project governance and license files**

Use the unmodified Apache License 2.0 text in `LICENSE`. `NOTICE` attributes ADB/AOSP references without claiming Google endorsement. `SECURITY.md` defines private vulnerability reporting and supported versions. `README.md` states macOS 13+/arm64, unsigned-build Gatekeeper steps through System Settings, managed ADB download behavior, privacy model, and known 1.0 limits. `CONTRIBUTING.md` documents Xcode 26.6 with Swift 6.3.3, Mint/XcodeGen, tests, configuration isolation, and commit expectations.

- [ ] **Step 11: Run the complete release gate**

```bash
make generate
make test
xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -configuration Release -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' build
FANTALOGCAT_DISTRIBUTION=public Scripts/verify_public_build.sh build/DerivedData/Build/Products/Release/FantaLogcat.app
Scripts/package_unsigned.sh build/DerivedData/Build/Products/Release/FantaLogcat.app dist
shasum -a 256 dist/*
```

Expected: every command exits 0; the bundle is arm64, contains no team defaults, and `dist` contains ZIP, DMG, checksum, NOTICE, and SBOM artifacts.

- [ ] **Step 12: Manual acceptance on a real device**

Verify USB authorization, Android 11+ wireless pair/connect, app restart PID tracking, Unity multiline stack traces, each IncentiveEngine preset from a team build, disconnect/reconnect, 100,000-event eviction notice, filtered/selected/time/context exports, AI omission notice, optional redaction preview, Chinese/English, VoiceOver, and a three-hour session. Record device model, Android version, ADB version, outcome, and artifact checksum in the GitHub Release checklist.

- [ ] **Step 13: Commit**

```bash
git add FantaLogcatApp FantaLogcatTests FantaLogcatUITests Scripts .github project.yml LICENSE NOTICE SECURITY.md CONTRIBUTING.md README.md
git commit -m "chore: harden FantaLogcat for public release"
```

---

## Final Verification Checklist

- [ ] `make test` passes with zero failures.
- [ ] Release build succeeds for `arm64` and deployment target remains macOS 13.0.
- [ ] First-run UI test reaches logs without exposing an ADB command.
- [ ] No public artifact contains `TeamDefaults.json`, internal package names, internal hosts, or raw team configuration.
- [ ] No production source launches a shell or interpolated command string.
- [ ] ADB download requires consent, verifies the pinned hash, and preserves the previous working version on failure.
- [ ] Log parsing preserves malformed input and UTF-8 split boundaries.
- [ ] Cache enforces both limits and reports evictions in UI and exports.
- [ ] Device reconnect, PID refresh, pause/resume, and clear semantics match the design.
- [ ] Export scopes, AI omission notices, atomic writes, and optional copy-only redaction are covered by tests.
- [ ] Chinese, English, keyboard navigation, VoiceOver, light mode, and dark mode pass UI review.
- [ ] README, SECURITY, NOTICE, Apache-2.0 license, SBOM, checksums, and unsigned Gatekeeper instructions ship with the release.

## Spec Coverage Map

| Design area | Implementing tasks |
| --- | --- |
| Product shell and beginner flow | 1, 6, 7, 10 |
| Log parsing, storage, session performance | 2, 3, 8, 10 |
| Safe ADB runtime and managed download | 4, 5 |
| USB/wireless device handling | 6 |
| App presets and PID tracking | 7, 9 |
| Filters and IncentiveEngine presets | 9, 10 |
| Three-layer configuration and public isolation | 9, 12 |
| Export, AI context, and redaction | 11 |
| Error recovery and diagnostics | 4–8, 11, 12 |
| Security, privacy, localization, accessibility | 4, 5, 9, 11, 12 |
| Testing, packaging, and GitHub release | all tasks, finalized in 12 |
