import SwiftUI

struct DiagnosticsView: View {
    @State private var tcpHost = "1.1.1.1"
    @State private var tcpPort = "443"
    @State private var tcpResult = ""
    @State private var proxyURL = "http://www.gstatic.com/generate_204"
    @State private var proxyResult = ""
    @State private var dnsAddr = "1.1.1.1:53"
    @State private var dnsResult = ""

    var body: some View {
        Form {
            Section("Direct TCP") {
                TextField("Host", text: $tcpHost)
                TextField("Port", text: $tcpPort).keyboardType(.numberPad)
                Button("Test") {
                    let port = Int32(tcpPort) ?? 443
                    tcpResult = MihomoDiagnostics.testDirectTCP(host: tcpHost, port: port)
                }
                if !tcpResult.isEmpty { Text(tcpResult).font(.caption.monospaced()) }
            }
            Section("Proxy HTTP") {
                TextField("URL", text: $proxyURL)
                Button("Test") { proxyResult = MihomoDiagnostics.testProxyHTTP(url: proxyURL) }
                if !proxyResult.isEmpty { Text(proxyResult).font(.caption.monospaced()) }
            }
            Section("DNS Resolver") {
                TextField("addr (host:port)", text: $dnsAddr)
                Button("Test") { dnsResult = MihomoDiagnostics.testDNSResolver(addr: dnsAddr) }
                if !dnsResult.isEmpty { Text(dnsResult).font(.caption.monospaced()) }
            }
        }
        .navigationTitle("Diagnostics")
    }
}

enum MihomoDiagnostics {
    static func testDirectTCP(host: String, port: Int32) -> String {
        #if MIHOMO_GO_LINKED
        var buf = [CChar](repeating: 0, count: 512)
        host.withCString { h in
            _ = meowTestDirectTcp(h, port, &buf, Int32(buf.count))
        }
        return String(cString: buf)
        #else
        return "Go bridge not linked"
        #endif
    }

    static func testProxyHTTP(url: String) -> String {
        #if MIHOMO_GO_LINKED
        var buf = [CChar](repeating: 0, count: 512)
        url.withCString { u in _ = meowTestProxyHttp(u, &buf, Int32(buf.count)) }
        return String(cString: buf)
        #else
        return "Go bridge not linked"
        #endif
    }

    static func testDNSResolver(addr: String) -> String {
        #if MIHOMO_GO_LINKED
        var buf = [CChar](repeating: 0, count: 512)
        addr.withCString { a in _ = meowTestDnsResolver(a, &buf, Int32(buf.count)) }
        return String(cString: buf)
        #else
        return "Go bridge not linked"
        #endif
    }
}

enum MihomoErrorReader {
    static func read() -> String {
        #if MIHOMO_GO_LINKED
        var buf = [CChar](repeating: 0, count: 512)
        _ = meowGetLastError(&buf, Int32(buf.count))
        return String(cString: buf)
        #else
        return ""
        #endif
    }
}
