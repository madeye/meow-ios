import SwiftUI

/// Form for adding a Shadowsocks server, either typed by hand or filled from
/// a scanned / pasted `ss://` link. Saving hands the server to
/// `SubscriptionService.addShadowsocks`, which renders it into the locally
/// generated template profile.
struct AddShadowsocksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionService.self) private var service
    @Binding var error: String?

    @State private var link = ""
    @State private var linkInvalid = false
    @State private var showingScanner = false

    @State private var name = ""
    @State private var server = ""
    @State private var port = ""
    @State private var cipher = ShadowsocksServer.defaultCipher
    @State private var password = ""
    @State private var udp = false

    @State private var pluginChoice: PluginChoice = .none

    // ECH-TLS tunnel fields.
    @State private var sni = ""
    @State private var path = ""
    @State private var echConfig = ""
    @State private var fingerprint = "chrome"
    @State private var fastOpen = false

    // simple-obfs fields.
    @State private var obfsMode = "http"
    @State private var obfsHost = ""

    // v2ray-plugin fields (websocket transport).
    @State private var v2rayTLS = false
    @State private var v2rayHost = ""
    @State private var v2rayPath = ""
    @State private var v2rayMux = false

    /// Plugin parsed from a link that the form has no dedicated fields for.
    /// Preserved verbatim so scanning an arbitrary SIP002 QR code doesn't
    /// silently drop its options; picking any explicit plugin replaces it.
    @State private var passthroughPlugin: PassthroughPlugin?

    @State private var submitting = false

    enum PluginChoice: String, CaseIterable, Identifiable {
        case none
        case ech
        case obfs
        case v2ray

        var id: String {
            rawValue
        }

        var labelKey: LocalizedStringKey {
            switch self {
            case .none: "ssAdd.plugin.none"
            case .ech: "ssAdd.plugin.ech"
            case .obfs: "ssAdd.plugin.obfs"
            case .v2ray: "ssAdd.plugin.v2ray"
            }
        }
    }

    struct PassthroughPlugin: Equatable {
        var name: String
        var opts: [ShadowsocksServer.PluginOption]
    }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                serverSection
                pluginSection
            }
            .navigationTitle("ssAdd.nav.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                        .accessibilityIdentifier("ssAdd.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey(
                        submitting ? "ssAdd.button.adding" : "ssAdd.button.add",
                    )) {
                        save()
                    }
                    .disabled(builtServer == nil || submitting)
                    .accessibilityIdentifier("ssAdd.addButton")
                }
            }
            .sheet(isPresented: $showingScanner) {
                ShadowsocksQRScannerSheet { payload in
                    link = payload
                    applyLink()
                }
            }
        }
    }

    // MARK: - Link import

    private func applyLink() {
        do {
            let parsed = try ShadowsocksURIParser.parse(link)
            apply(parsed)
            linkInvalid = false
        } catch {
            linkInvalid = true
        }
    }

    private func apply(_ parsed: ShadowsocksServer) {
        name = parsed.name
        server = parsed.server
        port = String(parsed.port)
        cipher = parsed.cipher
        password = parsed.password
        udp = parsed.udp
        passthroughPlugin = nil
        switch parsed.plugin {
        case ShadowsocksServer.echTLSPlugin:
            pluginChoice = .ech
            sni = parsed.pluginOption("sni") ?? ""
            path = parsed.pluginOption("path") ?? ""
            echConfig = parsed.pluginOption("ech_config") ?? ""
            fingerprint = parsed.pluginOption("fingerprint") ?? "chrome"
            fastOpen = parsed.pluginOption("fast_open") == "true"
        case ShadowsocksServer.obfsPlugin, "simple-obfs":
            pluginChoice = .obfs
            obfsMode = parsed.pluginOption("mode") ?? "http"
            obfsHost = parsed.pluginOption("host") ?? ""
        case ShadowsocksServer.v2rayPlugin:
            pluginChoice = .v2ray
            v2rayTLS = parsed.pluginOption("tls") == "true"
            v2rayHost = parsed.pluginOption("host") ?? ""
            v2rayPath = parsed.pluginOption("path") ?? ""
            v2rayMux = parsed.pluginOption("mux") == "true"
        case let .some(other):
            pluginChoice = .none
            passthroughPlugin = PassthroughPlugin(name: other, opts: parsed.pluginOpts)
        case nil:
            pluginChoice = .none
        }
    }

    // MARK: - Save

    private var builtServer: ShadowsocksServer? {
        let host = server.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !password.isEmpty, !cipher.isEmpty,
              let portValue = Int(port), (1 ... 65535).contains(portValue)
        else { return nil }

        let (plugin, opts) = builtPlugin(host: host)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        return ShadowsocksServer(
            name: trimmedName.isEmpty
                ? ShadowsocksServer.defaultName(server: host, port: portValue)
                : trimmedName,
            server: host,
            port: portValue,
            cipher: cipher,
            password: password,
            udp: udp,
            plugin: plugin,
            pluginOpts: opts,
        )
    }

    private func builtPlugin(host: String) -> (String?, [ShadowsocksServer.PluginOption]) {
        switch pluginChoice {
        case .none:
            passthroughPlugin.map { ($0.name, $0.opts) } ?? (nil, [])
        case .ech:
            (ShadowsocksServer.echTLSPlugin, echOpts(host: host))
        case .obfs:
            (ShadowsocksServer.obfsPlugin, obfsOpts())
        case .v2ray:
            (ShadowsocksServer.v2rayPlugin, v2rayOpts())
        }
    }

    private func echOpts(host: String) -> [ShadowsocksServer.PluginOption] {
        var opts: [ShadowsocksServer.PluginOption] = [.init("mode", "client")]
        let sniValue = sni.trimmingCharacters(in: .whitespaces)
        opts.append(.init("sni", sniValue.isEmpty ? host : sniValue))
        let pathValue = path.trimmingCharacters(in: .whitespaces)
        if !pathValue.isEmpty { opts.append(.init("path", pathValue)) }
        let echValue = echConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        if !echValue.isEmpty { opts.append(.init("ech_config", echValue)) }
        let fingerprintValue = fingerprint.trimmingCharacters(in: .whitespaces)
        if !fingerprintValue.isEmpty { opts.append(.init("fingerprint", fingerprintValue)) }
        if fastOpen { opts.append(.init("fast_open", "true")) }
        return opts
    }

    private func obfsOpts() -> [ShadowsocksServer.PluginOption] {
        var opts: [ShadowsocksServer.PluginOption] = [.init("mode", obfsMode)]
        let hostValue = obfsHost.trimmingCharacters(in: .whitespaces)
        if !hostValue.isEmpty { opts.append(.init("host", hostValue)) }
        return opts
    }

    private func v2rayOpts() -> [ShadowsocksServer.PluginOption] {
        var opts: [ShadowsocksServer.PluginOption] = [.init("mode", "websocket")]
        if v2rayTLS { opts.append(.init("tls", "true")) }
        let hostValue = v2rayHost.trimmingCharacters(in: .whitespaces)
        if !hostValue.isEmpty { opts.append(.init("host", hostValue)) }
        let pathValue = v2rayPath.trimmingCharacters(in: .whitespaces)
        if !pathValue.isEmpty { opts.append(.init("path", pathValue)) }
        if v2rayMux { opts.append(.init("mux", "true")) }
        return opts
    }

    private func save() {
        guard let built = builtServer else { return }
        submitting = true
        defer { submitting = false }
        do {
            _ = try service.addShadowsocks(built)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Form sections

extension AddShadowsocksSheet {
    private var linkSection: some View {
        Section {
            Button {
                showingScanner = true
            } label: {
                Label("ssAdd.button.scan", systemImage: "qrcode.viewfinder")
            }
            .accessibilityIdentifier("ssAdd.scanButton")

            // Placeholder is an example value, deliberately unlocalized.
            TextField("ss://…", text: $link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .onSubmit { applyLink() }
                .accessibilityIdentifier("ssAdd.linkField")
            if !link.isEmpty {
                Button("ssAdd.button.applyLink") { applyLink() }
                    .accessibilityIdentifier("ssAdd.applyLinkButton")
            }
        } header: {
            Text("ssAdd.section.link")
        } footer: {
            if linkInvalid {
                Text("ssAdd.error.invalidLink")
                    .foregroundStyle(.red)
            }
        }
    }

    private var serverSection: some View {
        Section {
            TextField("ssAdd.field.name", text: $name)
                .accessibilityIdentifier("ssAdd.nameField")
            TextField("ssAdd.field.server", text: $server)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("ssAdd.serverField")
            TextField("ssAdd.field.port", text: $port)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("ssAdd.portField")
            Picker("ssAdd.field.cipher", selection: $cipher) {
                ForEach(ShadowsocksServer.commonCiphers, id: \.self) { c in
                    Text(c).tag(c)
                }
                // A link can name a cipher outside the common list — keep it
                // selectable instead of snapping to a different one.
                if !ShadowsocksServer.commonCiphers.contains(cipher) {
                    Text(cipher).tag(cipher)
                }
            }
            .accessibilityIdentifier("ssAdd.cipherPicker")
            SecureField("ssAdd.field.password", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("ssAdd.passwordField")
            Toggle("ssAdd.toggle.udp", isOn: $udp)
                .accessibilityIdentifier("ssAdd.udpToggle")
        } header: {
            Text("ssAdd.section.server")
        } footer: {
            Text("ssAdd.footer.profile")
        }
    }

    private var pluginSection: some View {
        Section {
            Picker("ssAdd.plugin.picker", selection: $pluginChoice) {
                ForEach(PluginChoice.allCases) { choice in
                    Text(choice.labelKey).tag(choice)
                }
            }
            .accessibilityIdentifier("ssAdd.pluginPicker")
            .onChange(of: pluginChoice) { _, choice in
                if choice != .none { passthroughPlugin = nil }
            }
            switch pluginChoice {
            case .none:
                EmptyView()
            case .ech:
                echFields
            case .obfs:
                obfsFields
            case .v2ray:
                v2rayFields
            }
        } header: {
            Text("ssAdd.section.plugin")
        } footer: {
            pluginFooter
        }
    }

    @ViewBuilder
    private var pluginFooter: some View {
        switch pluginChoice {
        case .none:
            if let passthroughPlugin {
                Text("ssAdd.plugin.passthrough \(passthroughPlugin.name)")
            }
        case .ech:
            Text("ssAdd.ech.footer")
        case .obfs, .v2ray:
            // Empty host falls back to the server address in the engine.
            Text("ssAdd.plugin.hostFallback.footer")
        }
    }

    @ViewBuilder
    private var echFields: some View {
        TextField("ssAdd.field.sni", text: $sni)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssAdd.sniField")
        TextField("ssAdd.field.path", text: $path)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssAdd.pathField")
        TextField("ssAdd.field.echConfig", text: $echConfig)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssAdd.echConfigField")
        TextField("ssAdd.field.fingerprint", text: $fingerprint)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssAdd.fingerprintField")
        Toggle("ssAdd.toggle.fastOpen", isOn: $fastOpen)
            .accessibilityIdentifier("ssAdd.fastOpenToggle")
    }

    @ViewBuilder
    private var obfsFields: some View {
        Picker("ssAdd.field.obfsMode", selection: $obfsMode) {
            Text(verbatim: "http").tag("http")
            Text(verbatim: "tls").tag("tls")
        }
        .accessibilityIdentifier("ssAdd.obfsModePicker")
        TextField("ssAdd.field.obfsHost", text: $obfsHost)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssAdd.obfsHostField")
    }

    @ViewBuilder
    private var v2rayFields: some View {
        Toggle("ssAdd.toggle.v2rayTLS", isOn: $v2rayTLS)
            .accessibilityIdentifier("ssAdd.v2rayTLSToggle")
        TextField("ssAdd.field.v2rayHost", text: $v2rayHost)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssAdd.v2rayHostField")
        TextField("ssAdd.field.v2rayPath", text: $v2rayPath)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityIdentifier("ssAdd.v2rayPathField")
        Toggle("ssAdd.toggle.v2rayMux", isOn: $v2rayMux)
            .accessibilityIdentifier("ssAdd.v2rayMuxToggle")
    }
}
