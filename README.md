# FantaLogcat

FantaLogcat is a native macOS Logcat viewer for Android debugging. Connect a device, choose an installed process, and inspect the Logcat stream for that process without leaving your Mac.

## Requirements

- macOS 13 or later on Apple silicon (`arm64`)
- An Android device with Developer options and USB debugging enabled, or Wireless debugging enabled
- A USB cable for USB debugging; unlock the device and accept its USB debugging authorization prompt when asked

When Android tools are needed, review the Google license terms and choose **Accept and install**. FantaLogcat then downloads the official Android Platform-Tools package, verifies its SHA-256 checksum, and stores the managed copy in its app-support folder. It does not require a separately installed `adb`.

## Use

1. Connect or pair an Android device.
2. Accept USB debugging authorization on the device when prompted.
3. Select the app/process you want to inspect.
4. Start capture, filter or search the selected process's logs, and export the result when needed.

An unsigned app built locally can be blocked by Gatekeeper. In that case, open it once, then use **System Settings → Privacy & Security → Open Anyway** for that app. Do not disable Gatekeeper globally.

## Privacy and exports

Captured logs live in memory and are not retained as a log archive. Favorites and settings are stored locally on this Mac. Export is opt-in. The export sheet can redact common token, password, and key patterns, and redaction is enabled by default; it is not a guarantee that every secret, personal datum, or proprietary value is removed. Inspect every export before sharing it.

## Build and test

The repository provides these verified commands:

```sh
make generate
make test
make build
make release
```

`make release` creates an arm64 macOS ZIP in `build/releases` from a local build.

## 1.0 limitations

- FantaLogcat focuses on one selected process at a time rather than replacing every Android debugging tool.
- Device availability depends on Android Debug Bridge connectivity and device authorization.
- Wireless debugging must remain enabled and reachable on the device.
- Export redaction recognizes common patterns only and requires human review.

## Community and project policies

- [Contributing guide](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Apache License 2.0](LICENSE)
- [Notices](NOTICE)
- [Release checklist](docs/RELEASE_CHECKLIST.md)
