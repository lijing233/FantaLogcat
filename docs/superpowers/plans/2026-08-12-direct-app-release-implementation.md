# Direct App Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a directly launchable `FantaLogcat.app` and a ZIP from every release build.

**Architecture:** `make release` depends on the existing Release build, recreates `build/releases/FantaLogcat.app` using `ditto`, verifies the copied app, then creates a ZIP from that exact copy.

**Tech Stack:** Make, Xcode build tools, macOS `ditto`, `codesign`.

## Global Constraints

- Never launch the application as part of packaging.
- Preserve Finder metadata and resource forks using `ditto`.
- Fail packaging if the app binary, icon, or code signature is absent or invalid.

---

### Task 1: Add the direct-app release target

**Files:**
- Modify: `Makefile`

- [ ] Add `release` to `.PHONY`.
- [ ] Make `release` invoke `build`, recreate only `build/releases/FantaLogcat.app`, copy the built app with `ditto`, verify `AppIcon.icns` and code signature, then create `FantaLogcat-macos-arm64.zip` from the direct app.

### Task 2: Generate and inspect the delivery artifacts

**Files:**
- Create: `build/releases/FantaLogcat.app`
- Create: `build/releases/FantaLogcat-macos-arm64.zip`

- [ ] Run `make release`.
- [ ] Verify the app has an arm64 executable, `CFBundleIconName=AppIcon`, icon resources, and a valid signature.
