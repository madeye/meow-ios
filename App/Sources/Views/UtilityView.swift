import SwiftUI

private enum UtilityDestination: String, Identifiable {
    case traffic, logs, dns

    var id: String {
        rawValue
    }
}

struct UtilityView: View {
    @State private var destination: UtilityDestination? = Self.screenshotUtilityDestination()

    var body: some View {
        ScrollView {
            GlassCard {
                VStack(spacing: 0) {
                    NavRow(
                        title: "utility.nav.traffic",
                        systemImage: "chart.bar.fill",
                        identifier: "utility.nav.traffic",
                    ) { destination = .traffic }

                    Divider().padding(.leading, 42)

                    NavRow(
                        title: "utility.nav.logs",
                        systemImage: "list.bullet.rectangle.fill",
                        identifier: "utility.nav.logs",
                    ) { destination = .logs }

                    Divider().padding(.leading, 42)

                    NavRow(
                        title: "utility.nav.dns",
                        systemImage: "network",
                        identifier: "utility.nav.dns",
                    ) { destination = .dns }
                }
            }
            .padding(16)
        }
        .background(AppTheme.screenBackground)
        .scrollContentBackground(.hidden)
        .navigationTitle("utility.nav.title")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $destination) { target in
            switch target {
            case .traffic:
                TrafficView()
            case .logs:
                LogsView()
            case .dns:
                DnsView()
            }
        }
    }

    /// Screenshot harness: `-screenshotTab traffic` lands on Utility and
    /// auto-pushes Traffic so marketing captures stay unchanged.
    private static func screenshotUtilityDestination() -> UtilityDestination? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-UITests"),
              let i = args.firstIndex(of: "-screenshotTab"), i + 1 < args.count
        else { return nil }

        switch args[i + 1] {
        case "traffic": return .traffic
        case "logs": return .logs
        case "dns": return .dns
        default: return nil
        }
    }
}
