import SwiftUI

struct LogsView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var entries: [LogEntry] = []
    @State private var level = "info"
    @State private var autoScroll = true
    @State private var errorMessage: String?
    @State private var streamTask: Task<Void, Never>?

    var body: some View {
        VStack {
            HStack {
                Picker("Level", selection: $level) {
                    Text("debug").tag("debug")
                    Text("info").tag("info")
                    Text("warning").tag("warning")
                    Text("error").tag("error")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("logs.levelPicker")
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .labelsHidden()
                    .toggleStyle(.button)
                    .accessibilityIdentifier("logs.autoScrollToggle")
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                List(Array(entries.enumerated()), id: \.offset) { index, entry in
                    row(for: entry, index: index)
                        .id(index)
                }
                .listStyle(.plain)
                .overlay {
                    if entries.isEmpty {
                        ContentUnavailableView(
                            "No logs",
                            systemImage: "text.alignleft",
                            description: Text("Logs appear when the tunnel is active."),
                        )
                        .accessibilityIdentifier("logs.emptyState")
                    }
                }
                .onChange(of: entries.count) { _, count in
                    guard autoScroll, count > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .navigationTitle("Logs (\(entries.count))")
        .task(id: level) { await subscribe() }
    }

    private func row(for entry: LogEntry, index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.type.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(color(for: entry.type))
                .frame(width: 52, alignment: .leading)
                .accessibilityIdentifier("logs.row.\(index).level")
            Text(entry.payload)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("logs.row.\(index).message")
        }
        .accessibilityIdentifier("logs.row.\(index)")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityIdentifier("logs.errorBanner")
    }

    private func subscribe() async {
        streamTask?.cancel()
        entries.removeAll()
        let stream = api.streamLogs(level: level)
        do {
            for try await entry in stream {
                errorMessage = nil
                entries.append(entry)
                if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func color(for type: String) -> Color {
        switch type.lowercased() {
        case "debug": .secondary
        case "info": .blue
        case "warning": .orange
        case "error": .red
        default: .primary
        }
    }
}
