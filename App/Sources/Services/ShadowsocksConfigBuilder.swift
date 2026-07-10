import Foundation
import Yams

/// Config skeleton for locally-added Shadowsocks servers, derived from the
/// reference `ech-tls-mihomo.yaml` desktop config (credentials, providers,
/// and the reference deployment's own domains stripped). User servers are
/// injected into `proxies`, the 默认 group, and — for domain hosts — into
/// `fake-ip-filter` / sniffer `skip-domain` / a DIRECT rule, mirroring how
/// the reference config treats its own server domains.
private let shadowsocksTemplateYAML = """
mixed-port: 7890
ipv6: true
allow-lan: true
unified-delay: false
tcp-concurrent: true
external-controller: 127.0.0.1:9090

geodata-mode: true
geox-url:
  geoip: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip-lite.dat"
  geosite: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
  mmdb: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
  asn: "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb"

find-process-mode: strict
global-client-fingerprint: chrome

profile:
  store-selected: true
  store-fake-ip: true

sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080]
      override-destination: true
    TLS:
      ports: [443, 8443]
  skip-domain:
    - "Mijia Cloud"
    - "+.push.apple.com"

tun:
  enable: false
  stack: mixed
  dns-hijack:
    - "any:53"
    - "tcp://any:53"
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true

dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-filter:
    - "*"
    - "+.lan"
    - "+.local"
    - "+.market.xiaomi.com"
  default-nameserver:
    - tls://223.5.5.5
    - tls://223.6.6.6
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query

proxies:
  - name: "直连"
    type: direct
    udp: true

proxy-groups:
  - name: 默认
    type: select
    proxies: [自动选择, 直连, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点]

  - name: Google
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: Telegram
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: Twitter
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: 哔哩哔哩
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: 巴哈姆特
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: YouTube
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: NETFLIX
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: Spotify
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: Github
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: 国内
    type: select
    proxies: [直连, 默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择]

  - name: 其他
    type: select
    proxies: [默认, 香港, 台湾, 日本, 新加坡, 美国, 其它地区, 全部节点, 自动选择, 直连]

  - name: 香港
    type: select
    include-all: true
    exclude-type: [direct]
    filter: "(?i)港|hk|hongkong|hong kong"

  - name: 台湾
    type: select
    include-all: true
    exclude-type: [direct]
    filter: "(?i)台|tw|taiwan"

  - name: 日本
    type: select
    include-all: true
    exclude-type: [direct]
    filter: "(?i)日|jp|japan|tyo"

  - name: 美国
    type: select
    include-all: true
    exclude-type: [direct]
    filter: "(?i)美|us|unitedstates|united states"

  - name: 新加坡
    type: select
    include-all: true
    exclude-type: [direct]
    filter: "(?i)(新|sg|singapore|sgp)"

  - name: 其它地区
    type: select
    include-all: true
    exclude-type: [direct]
    filter: "(?i)^(?!.*(?:🇭🇰|🇯🇵|🇺🇸|🇸🇬|🇨🇳|港|hk|hongkong|台|tw|taiwan|日|jp|japan|tyo|新|sg|singapore|sgp|美|us|unitedstates)).*"

  - name: 全部节点
    type: select
    include-all: true
    exclude-type: [direct]

  - name: 自动选择
    type: url-test
    include-all: true
    exclude-type: [direct]
    tolerance: 10

rules:
  - GEOIP,lan,直连,no-resolve
  - GEOSITE,github,Github
  - GEOSITE,twitter,Twitter
  - GEOSITE,youtube,YouTube
  - GEOSITE,google,Google
  - GEOSITE,telegram,Telegram
  - GEOSITE,netflix,NETFLIX
  - GEOSITE,bilibili,哔哩哔哩
  - GEOSITE,bahamut,巴哈姆特
  - GEOSITE,spotify,Spotify
  - GEOSITE,CN,国内
  - GEOSITE,geolocation-!cn,其他
  - GEOIP,google,Google
  - GEOIP,netflix,NETFLIX
  - GEOIP,telegram,Telegram
  - GEOIP,twitter,Twitter
  - GEOIP,CN,国内
  - MATCH,其他
"""

/// Renders local Shadowsocks-server profiles from the built-in template and
/// reads the servers back out of a previously rendered profile so repeated
/// adds accumulate into one profile.
enum ShadowsocksConfigBuilder {
    /// First line of every rendered profile. Lets the subscription service
    /// find the locally generated profile among imported ones.
    static let marker = "# meow:ss-local-profile"

    static let directProxyName = "直连"
    static let defaultGroupName = "默认"

    enum BuildError: Error {
        case templateBroken
    }

    static func isGenerated(_ yaml: String) -> Bool {
        yaml.hasPrefix(marker)
    }

    static func render(servers: [ShadowsocksServer]) throws -> String {
        guard var root = try Yams.compose(yaml: shadowsocksTemplateYAML) else {
            throw BuildError.templateBroken
        }

        guard let existing = root["proxies"]?.sequence.map({ Array($0) }) else {
            throw BuildError.templateBroken
        }
        root["proxies"] = Node(existing + servers.map(proxyNode))

        guard var groups = root["proxy-groups"]?.sequence.map({ Array($0) }) else {
            throw BuildError.templateBroken
        }
        for index in groups.indices where groups[index]["name"]?.string == defaultGroupName {
            guard var members = groups[index]["proxies"]?.sequence.map({ Array($0) }) else { continue }
            // After 自动选择 + 直连, before the region groups — matching where
            // the reference config lists its own servers.
            let insertAt = min(2, members.count)
            members.insert(contentsOf: servers.map { quoted($0.name) }, at: insertAt)
            groups[index]["proxies"] = Node(members)
        }
        root["proxy-groups"] = Node(groups)

        insertDomainEntries(into: &root, servers: servers)

        let yaml = try Yams.serialize(node: root, width: -1, allowUnicode: true)
        return marker + "\n" + yaml
    }

    static func extractServers(from yaml: String) -> [ShadowsocksServer] {
        guard let root = try? Yams.compose(yaml: yaml),
              let proxies = root["proxies"]?.sequence
        else { return [] }
        var servers: [ShadowsocksServer] = []
        for node in proxies where node["type"]?.string == "ss" {
            guard let name = node["name"]?.string,
                  let server = node["server"]?.string,
                  let port = node["port"]?.int,
                  let cipher = node["cipher"]?.string,
                  let password = node["password"]?.string
            else { continue }
            var opts: [ShadowsocksServer.PluginOption] = []
            if let mapping = node["plugin-opts"]?.mapping {
                for (key, value) in mapping {
                    guard let keyText = key.string else { continue }
                    if let flag = value.bool {
                        opts.append(.init(keyText, flag ? "true" : "false"))
                    } else {
                        opts.append(.init(keyText, value.string ?? ""))
                    }
                }
            }
            servers.append(ShadowsocksServer(
                name: name,
                server: server,
                port: port,
                cipher: cipher,
                password: password,
                udp: node["udp"]?.bool ?? false,
                plugin: node["plugin"]?.string,
                pluginOpts: opts,
            ))
        }
        return servers
    }

    // MARK: - Node assembly

    private static func proxyNode(_ server: ShadowsocksServer) -> Node {
        var pairs: [(Node, Node)] = [
            ("name", quoted(server.name)),
            ("type", Node("ss")),
            ("server", quoted(server.server)),
            ("port", Node(String(server.port), Tag(.int))),
            ("cipher", Node(server.cipher)),
            ("password", quoted(server.password)),
            ("udp", boolNode(server.udp)),
        ]
        if let plugin = server.plugin, !plugin.isEmpty {
            pairs.append(("plugin", Node(plugin)))
            if !server.pluginOpts.isEmpty {
                let optPairs: [(Node, Node)] = server.pluginOpts.map { opt in
                    let value: Node = (opt.value == "true" || opt.value == "false")
                        ? boolNode(opt.value == "true")
                        : quoted(opt.value)
                    return (Node(opt.key), value)
                }
                pairs.append(("plugin-opts", Node(optPairs)))
            }
        }
        return Node(pairs)
    }

    /// Per-server treatment of domain hosts (IP-literal servers need none):
    /// keep the server's own name out of fake-IP and route direct hits to it
    /// outside the tunnel, exactly as the reference config does for its
    /// deployment domain.
    private static func insertDomainEntries(into root: inout Node, servers: [ShadowsocksServer]) {
        var domains: [String] = []
        for server in servers where !isIPAddress(server.server) && !domains.contains(server.server) {
            domains.append(server.server)
        }
        guard !domains.isEmpty else { return }

        let wildcarded = domains.map { quoted("+.\($0)") }
        if var filter = root["dns"]?["fake-ip-filter"]?.sequence.map({ Array($0) }) {
            filter.append(contentsOf: wildcarded)
            root["dns"]?["fake-ip-filter"] = Node(filter)
        }
        if var skip = root["sniffer"]?["skip-domain"]?.sequence.map({ Array($0) }) {
            skip.append(contentsOf: wildcarded)
            root["sniffer"]?["skip-domain"] = Node(skip)
        }
        if var rules = root["rules"]?.sequence.map({ Array($0) }) {
            let directRules = domains.map { Node("DOMAIN-SUFFIX,\($0),\(directProxyName)") }
            rules.insert(contentsOf: directRules, at: rules.isEmpty ? 0 : 1)
            root["rules"] = Node(rules)
        }
    }

    /// Force-quoted string scalar so values that look like other YAML types
    /// (numeric passwords, `true`, emoji-prefixed names) stay strings.
    private static func quoted(_ value: String) -> Node {
        Node(value, Tag(.str), .doubleQuoted)
    }

    private static func boolNode(_ value: Bool) -> Node {
        Node(value ? "true" : "false", Tag(.bool))
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { cstr in
            inet_pton(AF_INET, cstr, &v4) == 1 || inet_pton(AF_INET6, cstr, &v6) == 1
        }
    }
}
