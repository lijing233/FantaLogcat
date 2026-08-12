import SwiftUI

struct LogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.returnToAppSelection()
            } label: {
                Label("Apps", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedApp?.presentation.displayName ?? "Logs")
                    .font(.headline)
                Text(model.selectedApp?.packageName.value ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isLogStreaming {
                Label("Live", systemImage: "record.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            Text("\(model.logEvents.count) events")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Clear") {
                model.clearLogs()
            }
            .disabled(model.logEvents.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.logEvents.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: model.logStreamError == nil ? "waveform.path.ecg" : "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(model.logStreamError == nil ? Color.secondary : Color.orange)
                Text(emptyTitle)
                    .font(.headline)
                Text(emptyDescription)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.logEvents) { event in
                        LogRow(event: event)
                        Divider().opacity(0.45)
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        model.logStreamError == nil ? "Waiting for logs" : "Log stream stopped"
    }

    private var emptyDescription: String {
        if let error = model.logStreamError {
            return "ADB error: \(error). Reconnect the device and choose the app again."
        }
        return "Start or use the selected Android app. New Logcat output will appear here automatically."
    }
}

private struct LogRow: View {
    let event: LogEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(priorityMarker)
                .font(.caption.bold().monospaced())
                .foregroundStyle(priorityColor)
                .frame(width: 14)
            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(event.androidTag ?? "raw")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            Text(event.message)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var priorityMarker: String {
        switch event.priority {
        case .verbose: "V"
        case .debug: "D"
        case .info: "I"
        case .warning: "W"
        case .error: "E"
        case .fatal: "F"
        case .unknown: "?"
        }
    }

    private var priorityColor: Color {
        switch event.priority {
        case .warning: .orange
        case .error, .fatal: .red
        case .debug: .purple
        case .verbose: .secondary
        default: .primary
        }
    }

    private var timeText: String {
        guard let timestamp = event.deviceTimestamp else { return "--:--:--" }
        return timestamp.formatted(date: .omitted, time: .standard)
    }
}
