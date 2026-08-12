# Log Capture Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make capture app-scoped across app restarts, expose understandable filters, export, and bounded preferences.

**Architecture:** AppModel polls only the selected package until a PID exists, then replays and streams that PID. Preferences construct bounded session limits. LogExporter serializes a filtered or all-cached snapshot only when the user confirms a save panel.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest.

## Global Constraints

- No unfiltered logcat fallback when an app has no PID.
- No Android app state mutation; no clear logcat operation.
- Hard safety ceilings: 500 history rows, 100,000 events, 64 MiB text cache.
- Compile tests and build only; do not execute an app-launching test runner.

---

### Task 1: App-scoped restart-safe capture

**Files:** `Application/AppModel.swift`, `Logs/LogSession.swift`, `Application/AppModelTests.swift`

- [ ] Add waiting state and package-PID polling.
- [ ] Do not create snapshot or live logcat commands without at least one PID.
- [ ] Preserve captured rows across a PID restart and assign unique UI event IDs.

### Task 2: Bounded preferences and export domain

**Files:** `Logs/LogCaptureSettings.swift`, `Logs/LogExporter.swift`, corresponding tests.

- [ ] Persist and validate history count, event count, byte cache, and redaction default.
- [ ] Export selected cached rows as threadtime text with optional common-secret redaction.

### Task 3: UI controls

**Files:** `UI/LogView.swift`, `UI/SettingsView.swift`, `Application/AppModel.swift`

- [ ] Replace abbreviated priority controls with named toggle buttons and checkmarks.
- [ ] Add export scope and redaction sheet.
- [ ] Add settings steppers/toggles for the safe configuration range.

### Task 4: Non-launch verification and release package

- [ ] Build test targets, build Release, verify signing and icon, package ZIP.
