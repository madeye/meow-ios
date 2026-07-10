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

    @State private var echEnabled = false
    @State private var sni = ""
    @State private var path = ""
    @State private var echConfig = ""
    @State private var fingerprint = "chrome"
    @State private var fastOpen = false

    /// Plugin parsed from a link that isn't ech-tls-tunnel. Preserved
    /// verbatim so scanning an arbitrary SIP002 QR code doesn't silently
    /// drop its plugin options; toggling the ECH section replaces it.
    @State private var passthroughPlugin: PassthroughPlugin?

    @State private var submitting = false

    private struct PassthroughPlugin: Equatable {
        var name: String
        var opts: [ShadowsocksServer.PluginOption]
    }

    var body: some View {
        NavigationStack {
            Form {
                linkSection
                serverSection
                echSection
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
            if let passthroughPlugin {
                Text("ssAdd.plugin.passthrough \(passthroughPlugin.name)")
            } else {
                Text("ssAdd.footer.profile")
            }
        }
    }

    private var echSection: some View {
        Section {
            Toggle("ssAdd.toggle.ech", isOn: $echEnabled)
                .accessibilityIdentifier("ssAdd.echToggle")
                .onChange(of: echEnabled) { _, enabled in
                    if enabled { passthroughPlugin = nil }
                }
            if echEnabled {
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
        } header: {
            Text("ssAdd.section.ech")
        } footer: {
            Text("ssAdd.ech.footer")
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
        if parsed.plugin == ShadowsocksServer.echTLSPlugin {
            echEnabled = true
            passthroughPlugin = nil
            sni = parsed.pluginOption("sni") ?? ""
            path = parsed.pluginOption("path") ?? ""
            echConfig = parsed.pluginOption("ech_config") ?? ""
            fingerprint = parsed.pluginOption("fingerprint") ?? "chrome"
            fastOpen = parsed.pluginOption("fast_open") == "true"
        } else if let plugin = parsed.plugin {
            echEnabled = false
            passthroughPlugin = PassthroughPlugin(name: plugin, opts: parsed.pluginOpts)
        } else {
            echEnabled = false
            passthroughPlugin = nil
        }
    }

    // MARK: - Save

    private var builtServer: ShadowsocksServer? {
        let host = server.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !password.isEmpty, !cipher.isEmpty,
              let portValue = Int(port), (1 ... 65535).contains(portValue)
        else { return nil }

        var plugin: String?
        var opts: [ShadowsocksServer.PluginOption] = []
        if echEnabled {
            plugin = ShadowsocksServer.echTLSPlugin
            opts.append(.init("mode", "client"))
            let sniValue = sni.trimmingCharacters(in: .whitespaces)
            opts.append(.init("sni", sniValue.isEmpty ? host : sniValue))
            let pathValue = path.trimmingCharacters(in: .whitespaces)
            if !pathValue.isEmpty { opts.append(.init("path", pathValue)) }
            let echValue = echConfig.trimmingCharacters(in: .whitespacesAndNewlines)
            if !echValue.isEmpty { opts.append(.init("ech_config", echValue)) }
            let fingerprintValue = fingerprint.trimmingCharacters(in: .whitespaces)
            if !fingerprintValue.isEmpty { opts.append(.init("fingerprint", fingerprintValue)) }
            if fastOpen { opts.append(.init("fast_open", "true")) }
        } else if let passthroughPlugin {
            plugin = passthroughPlugin.name
            opts = passthroughPlugin.opts
        }

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
