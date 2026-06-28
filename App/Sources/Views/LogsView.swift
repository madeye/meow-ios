import SwiftUI

struct LogsView: View {
    @Environment(MeowAPI.self) private var api
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var allEntries: [LogEntry] = []
    @State private var level = "info"
    @State private var autoScroll = true
    @State private var errorMessage: String?
    @State private var streamTask: Task<Void, Never>?

    private static let levelOrder = ["debug": 0, "info": 1, "warning": 2, "error": 3]

    private var entries: [LogEntry] {
        let threshold = Self.levelOrder[level] ?? 0
        return allEntries.filter { (Self.levelOrder[$0.type.lowercased()] ?? 0) >= threshold }
    }

    var body: some View {
        VStack {
            HStack {
                Picker("logs.picker.level", selection: $level) {
                    Text("logs.level.debug").tag("debug")
                    Text("logs.level.info").tag("info")
                    Text("logs.level.warning").tag("warning")
                    Text("logs.level.error").tag("error")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("logs.levelPicker")
                Toggle("logs.toggle.autoScroll", isOn: $autoScroll)
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
                            "logs.empty.title",
                            systemImage: "text.alignleft",
                            description: Text("logs.empty.description"),
                        )
                        .accessibilityIdentifier("logs.emptyState")
                    }
                }
                .onChange(of: entries.count) { _, count in
                    guard autoScroll, count > 0 else { return }
                    if reduceMotion {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    } else {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
        }
        .navigationTitle(Text(
            "logs.nav.titleFormat \(entries.count)",
            comment: "Logs screen navigation title; %lld = entry count",
        ))
        .navigationBarTitleDisplayMode(.inline)
        .task { await subscribe() }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("a11y.logs.row.label \(entry.type.uppercased()) \(entry.payload)"))
        .accessibilityIdentifier("logs.row.\(index)")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("a11y.logs.errorBanner.label \(message)"))
        .accessibilityIdentifier("logs.errorBanner")
    }

    private func subscribe() async {
        streamTask?.cancel()
        let stream = api.streamLogs(level: "debug")
        do {
            for try await entry in stream {
                errorMessage = nil
                allEntries.append(entry)
                if allEntries.count > 2000 { allEntries.removeFirst(allEntries.count - 2000) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func color(for type: String) -> Color {
        switch type.lowercased() {
        case "debug": .secondary
        case "info": AppTheme.accent
        case "warning": AppTheme.warning
        case "error": AppTheme.danger
        default: .primary
        }
    }
}
