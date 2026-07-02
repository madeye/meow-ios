import SwiftUI

struct LogsView: View {
    @Environment(UtilityLogsStore.self) private var logsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let levelOrder = ["debug": 0, "info": 1, "warning": 2, "error": 3]

    private var entries: [LogEntry] {
        let threshold = Self.levelOrder[logsStore.level] ?? 0
        return logsStore.allEntries.filter { (Self.levelOrder[$0.type.lowercased()] ?? 0) >= threshold }
    }

    var body: some View {
        VStack {
            HStack {
                Picker("logs.picker.level", selection: levelBinding) {
                    Text("logs.level.debug").tag("debug")
                    Text("logs.level.info").tag("info")
                    Text("logs.level.warning").tag("warning")
                    Text("logs.level.error").tag("error")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("logs.levelPicker")
                Toggle("logs.toggle.autoScroll", isOn: autoScrollBinding)
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
                    guard logsStore.autoScroll, count > 0 else { return }
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
            if let errorMessage = logsStore.errorMessage {
                ErrorBanner(
                    message: errorMessage,
                    accessibilityLabel: Text("a11y.logs.errorBanner.label \(errorMessage)"),
                    identifier: "logs.errorBanner",
                )
            }
        }
        .navigationTitle(Text(
            "logs.nav.titleFormat \(entries.count)",
            comment: "Logs screen navigation title; %lld = entry count",
        ))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var levelBinding: Binding<String> {
        Binding(
            get: { logsStore.level },
            set: { logsStore.level = $0 },
        )
    }

    private var autoScrollBinding: Binding<Bool> {
        Binding(
            get: { logsStore.autoScroll },
            set: { logsStore.autoScroll = $0 },
        )
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
