import SwiftUI

struct LogsView: View {
    @Environment(MihomoAPI.self) private var api
    @State private var entries: [LogEntry] = []
    @State private var level = "info"
    @State private var autoScroll = true
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
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .labelsHidden()
                    .toggleStyle(.button)
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                List(Array(entries.enumerated()), id: \.offset) { index, entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.type.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(color(for: entry.type))
                            .frame(width: 52, alignment: .leading)
                        Text(entry.payload)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    .id(index)
                }
                .listStyle(.plain)
                .onChange(of: entries.count) { _, count in
                    guard autoScroll, count > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .task(id: level) { await subscribe() }
    }

    private func subscribe() async {
        streamTask?.cancel()
        entries.removeAll()
        let stream = api.streamLogs(level: level)
        do {
            for try await entry in stream {
                entries.append(entry)
                if entries.count > 2000 { entries.removeFirst(entries.count - 2000) }
            }
        } catch {
            // Stream ended / failed; silently recover on next appear.
        }
    }

    private func color(for type: String) -> Color {
        switch type.lowercased() {
        case "debug": return .secondary
        case "info": return .blue
        case "warning": return .orange
        case "error": return .red
        default: return .primary
        }
    }
}
