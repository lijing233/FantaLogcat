# Log History Replay Design

## Goal

When a user selects an Android app, FantaLogcat first shows a bounded slice of that app's existing logcat buffer and then follows new output in real time.

## Decision

Use `adb logcat -d -t 500 -v threadtime --pid=<pid>` for the initial snapshot, followed by the existing streaming command. The snapshot is read-only: it neither clears logcat nor changes the app's state. A package without a current PID falls back to the existing unfiltered behavior and explicitly reports that scope.

## Constraints

- Keep the current process scope by default so unrelated app logs do not overwhelm beginners.
- The snapshot is capped at 500 lines and uses the existing parser and bounded event buffer.
- Do not launch, stop, install, or clear any Android app or device log buffer.
- If the snapshot command fails, continue with live logging and expose the error code.

## User Experience

The first visible entries include recent startup and pre-selection logs. Live entries then continue below them. The user can use saved keyword filters such as `IncentiveEngineManager`, `IAA`, and `CloudConfig`; those library logs are in the selected game's process.
