# Log Capture Controls Design

When the selected Android app has no running process, FantaLogcat waits and polls its package process list; it never falls back to unfiltered device logcat. A new PID after an app restart begins a fresh bounded snapshot and live stream while retaining prior captured rows.

The log toolbar uses complete priority labels with selected-state checkmarks and toggle-off behavior. Export writes user-selected cached rows to a user-selected `.txt` file, optionally redacting common credential values. Settings persist bounded history, event-count, byte-cache, and redaction defaults; all controls have non-negotiable safety ceilings.
