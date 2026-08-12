# Log History Replay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replay a bounded set of recent Android logs when a user selects an app, then continue live streaming.

**Architecture:** Add a closed-argument ADB snapshot command and a `LogSession` snapshot API. `AppModel` appends snapshot events before consuming the existing live stream, so both paths share the bounded parser and ring buffer.

**Tech Stack:** Swift 6, SwiftUI, XCTest, adb.

## Global Constraints

- macOS arm64 only; deployment target macOS 13.
- Snapshot uses `adb logcat -d -t 500`; no clear, launch, stop, or install command.
- Do not run test commands that launch FantaLogcat; compile test targets only.

---

### Task 1: Add a bounded snapshot command

**Files:**
- Modify: `FantaLogcatApp/ADB/ADBCommand.swift`
- Modify: `FantaLogcatTests/ADB/ADBRuntimeTests.swift`

- [ ] Add `logcatSnapshotThreadtime(_:pids:lineCount:)`, clamping its line count to `1...500` and emitting `-d -t <count>` before any PID flags.
- [ ] Add an XCTest assertion for its exact argument array.

### Task 2: Replay parsed snapshot events before live events

**Files:**
- Modify: `FantaLogcatApp/Logs/LogSession.swift`
- Modify: `FantaLogcatTests/Logs/LogSessionTests.swift`
- Modify: `FantaLogcatApp/Application/AppModel.swift`
- Modify: `FantaLogcatTests/Application/AppModelTests.swift`

- [ ] Add `recentEvents(on:pids:limit:)` to `LogSessionProtocol`.
- [ ] Parse the bounded snapshot through `LogcatParser` and expose its events.
- [ ] Append snapshot events before starting the existing live stream.
- [ ] Add tests for command selection, parser output, and snapshot-before-live ordering.

### Task 3: Verify without launching the app

**Files:**
- Modify: none

- [ ] Run `xcodebuild build-for-testing` for the macOS arm64 scheme.
- [ ] Build the Release app, verify its icon and signature, and create the arm64 ZIP.
