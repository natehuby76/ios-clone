import SwiftUI
import WebKit
import VisionKit
import AVFoundation

struct ConnectionSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bluetooth: BluetoothTransport
    @ObservedObject var lan: LANTransport
    @ObservedObject var assets: GalaxyAssetStore
    @ObservedObject var server: LoopbackServer
    @ObservedObject var discovery: LANDiscovery
    @ObservedObject var location: PhoneLocation
    @ObservedObject var audio: AudioPairing
    let returningFromGalaxy: Bool
    let select: (CompanionTab) -> Void
    let submitReport: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("galaxy.app.language") private var language = "en"
    @AppStorage("galaxy.app.followGalaxyLanguage") private var followGalaxyLanguage = true
    @AppStorage("galaxy.location.hideIndicator") private var hideLocationIndicator = false
    @State private var showOrder = false
    @State private var showTunnel = false
    @State private var advanced = false
    @State private var confirmForget = false
    @State private var confirmNavigationAlpha = false
    @State private var showPairingHelp = false
    @State private var checked = false
    @State private var openAfterReconnect = false
    @State private var connectingCommaID: String?
    @State private var showHotspotJoin = false

    private var accent: Color { colorScheme == .dark ? Color(red: 0.68, green: 0.48, blue: 0.96) : Color(red: 0.45, green: 0.26, blue: 0.73) }
    private var background: Color { colorScheme == .dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.93, green: 0.90, blue: 0.98) }
    private var panel: Color { colorScheme == .dark ? Color(red: 0.09, green: 0.065, blue: 0.145) : Color(red: 0.88, green: 0.83, blue: 0.95) }
    private var muted: Color { colorScheme == .dark ? Color(red: 0.70, green: 0.65, blue: 0.77) : Color(red: 0.36, green: 0.29, blue: 0.46) }
    private var connected: Bool { model.transport.connected }
    private var pairing: Bool { model.pairingInProgress }
    private var needsPairing: Bool {
        model.mode == .bluetooth && (Data(hex: model.pairingKey)?.count != 32 || !bluetooth.hasSavedDevice || bluetooth.pairingRecoveryNeeded)
    }
    private var connecting: Bool { !connected && (bluetooth.connecting || bluetooth.isScanning) }
    private var primaryTitle: String {
        if pairing { return "Pairing…" }
        if connected { return model.opened ? "Open Galaxy" : "Preparing Galaxy…" }
        if connecting { return bluetooth.isScanning ? "Finding comma…" : "Connecting…" }
        if needsPairing {
            if !model.hasLANPairingSetup { return "Connect over Local Wi-Fi first" }
            if bluetooth.pairingRecoveryNeeded { return "Pair Bluetooth again" }
            return model.pairingFailure.isEmpty ? "Set up Bluetooth" : "Retry Bluetooth setup"
        }
        if model.mode == .bluetooth { return "Reconnect Bluetooth" }
        return "Connect"
    }
    private var connectionCandidates: [DiscoveredComma] {
        var devices = discovery.devices
        if let host = try? LANTransport.endpoint(model.address).host,
           !devices.contains(where: { $0.address == host }) {
            devices.append(DiscoveredComma(id: "manual-" + host, name: "Comma", address: host))
        }
        return devices
    }

    private var checking: Bool { model.matchingGalaxy || assets.checking }
    private var status: String { pairing ? "Pairing with comma…" : connected ? "Connected via \(model.transport.label)" : connecting ? "Connecting to comma…" : "Not connected" }

    init(model: AppModel, returningFromGalaxy: Bool, select: @escaping (CompanionTab) -> Void, submitReport: @escaping () -> Void) {
        self.model = model; self.returningFromGalaxy = returningFromGalaxy; self.select = select
        self.submitReport = submitReport
        bluetooth = model.bluetooth; lan = model.lan; assets = model.assets; server = model.server
        discovery = model.discovery; location = model.phoneLocation; audio = model.audioPairing
    }

    var body: some View {
        if DuoLayout.isEnabled {
            GeometryReader { geometry in
                // Keep the system-provided safe-area width. Ignoring the horizontal
                // safe area here lets the cards extend behind Duo's toolbar rail.
                let width = max(0, geometry.size.width)
                let wide = width >= 640 && !dynamicTypeSize.isAccessibilitySize
                settingsContent(wide: wide)
                    .frame(width: width, height: geometry.size.height)
            }
        } else {
            settingsContent(wide: false)
        }
    }

    private func settingsContent(wide: Bool) -> some View {
        ScrollView {
            settingsPage(wide: wide)
        }.scrollBounceBehavior(.basedOnSize).background {
            if model.navigationEnabled { LinearGradient(colors: [background, panel.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea() }
            else { background.ignoresSafeArea() }
        }.foregroundStyle(Color.primary).preferredColorScheme(model.navigationEnabled ? nil : .dark)
            .alert("Enable navigation alpha?", isPresented: $confirmNavigationAlpha) {
                Button("Cancel", role: .cancel) { }
                Button("Enable alpha") { model.navigationAlpha = true }
            } message: {
                Text("Navigation and CarPlay maps are experimental and may stop working or show incorrect guidance. Check directions independently. You can turn this off at any time.")
            }
            .onChange(of: connected) { _, _ in openReconnectedGalaxy() }
            .onChange(of: pairing) { _, value in if value { openAfterReconnect = false } }
            .onChange(of: model.opened) { _, _ in openReconnectedGalaxy() }
            .onChange(of: model.wantsConnection) { _, value in if !value { openAfterReconnect = false } }
            .sheet(isPresented: $showOrder) {
                NavigationStack {
                    List {
                        Section {
                            ForEach(model.connectionPriority) { route in
                                Label { Text(LocalizedStringKey(route.title)) } icon: {
                                    if route == .tunnel { Image(systemName: "network") }
                                    else { Image(route == .lan ? "ConnectionWiFi" : "ConnectionBluetooth").renderingMode(.template).resizable().scaledToFit().frame(width: 22, height: 22) }
                                }
                            }.onMove { from, to in model.connectionPriority.move(fromOffsets: from, toOffset: to) }
                        } footer: { Text("Automatic uses the first available connection. Drag to change the order. Local Wi-Fi-only and Bluetooth-only ignore this order.") }
                        Button("Reset order") { model.connectionPriority = ConnectionRoute.allCases }
                    }.environment(\.editMode, .constant(.active))
                        .navigationTitle("Connection order").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showOrder = false } } }
                }.presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showTunnel) { TunnelSetupView(model: model) }
            .tint(accent)
            .alert("Join comma’s hotspot", isPresented: $showHotspotJoin) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This hotspot address is available in the device list, but your iPhone couldn’t reach and verify comma there. In iPhone Settings → Wi-Fi, join comma’s TheGalaxy-… network using the hotspot password shown on comma. Then return here and tap the comma row again.")
            }
            .alert("Reconnect Bluetooth", isPresented: $showPairingHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("1. Keep comma powered on and nearby, with Bluetooth enabled. Allow this app Bluetooth access in iPhone Settings.\n2. Try reconnecting. If key verification repeatedly fails, the main button will offer pairing again.\n3. To pair again, join comma’s Wi-Fi network or hotspot. If the saved address cannot be reached, choose Local Wi-Fi in this app and select comma, then return to Bluetooth.\n4. Tap the setup button. The app opens the pairing window on comma automatically and shows progress here.\n\nYou normally do not need to tap Pair on comma or forget devices in iPhone Bluetooth settings. Audio pairing is separate from this app connection.")
            }
            .confirmationDialog("Forget Bluetooth pairing?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget pairing", role: .destructive) {
                    model.disconnect(); bluetooth.forgetSavedDevice(); PairingKeyStore.remove(); model.pairingKey = ""
                    lan.bind(to: nil); UserDefaults.standard.removeObject(forKey: "galaxy.comma.identity")
                }
            } message: { Text("This removes the saved app pairing. Pair your phone again to reconnect.") }
    }

    private func settingsPage(wide: Bool) -> AnyView {
        // Bound the concrete SwiftUI type at the page boundary. Keep one page tree
        // instead of nesting multiple complete pages in a fitting container.
        AnyView(VStack(spacing: 8) {
            HStack {
                if returningFromGalaxy && model.opened {
                    Button { select(.galaxy) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("Back to Galaxy")
                } else { Color.clear.frame(width: 44, height: 44) }
                Spacer(minLength: 0)
                Text(returningFromGalaxy ? "Settings" : "StarPilot BT")
                    .font(.custom("Sora-Regular", size: 22).weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
                Color.clear.frame(width: 44, height: 44)
            }
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        preferencesHeading
                        preferences(extraSpacing: 3)
                    }.frame(maxWidth: .infinity)

                    VStack(spacing: 8) {
                        connectionPanel(extraSpacing: 6)
                        connectionExtras
                    }.frame(maxWidth: .infinity)
                }
                .padding(.top, 12)
            } else {
                ConnectionOrbit(route: connected ? model.transport.label : "", pairing: pairing)
                    .padding(.bottom, 10)
                connectionPanel()
                preferencesHeading
                preferences()
                connectionExtras
            }
            if wide {
                HStack(spacing: 24) {
                    footerLinks
                    languageMenu
                    versionLabel
                }.frame(maxWidth: .infinity).padding(.top, 8)
            } else {
                footerLinks
                languageMenu
            }
            if !model.legacyMessage.isEmpty { message(model.legacyMessage) }
            if !server.error.isEmpty { message(server.error) }
            if !wide { versionLabel }

        }.padding(.horizontal, 18).padding(.top, 0).padding(.bottom, 12)
            .frame(maxWidth: wide ? 1200 : 460).frame(maxWidth: .infinity))
    }

    private var footerLinks: some View {
        HStack(spacing: 18) {
            Button(model.loadingLegacyURL ? "Getting link…" : "Legacy Galaxy") {
                Task { if let url = await model.fetchLegacyURL() {
                    openURL(url) { accepted in if !accepted { model.legacyMessage = "Couldn’t open your browser. Try again." } }
                } }
            }.disabled(model.loadingLegacyURL || pairing)
            Link("Support", destination: URL(string: "https://wiki.firestar.link/ticketsystem/")!)
            Link("Privacy", destination: URL(string: "https://github.com/natehuby76/ios-clone/blob/codex/secretgood-galaxy/docs/privacy.md")!)
        }.font(.system(size: 12)).frame(minHeight: 44)
    }

    private var languageMenu: some View {
        Menu {
            Button("English") { language = "en" }
            Button("Español") { language = "es" }
            Button("Français") { language = "fr" }
            Button("한국어") { language = "ko" }
            Button("简体中文") { language = "zh-Hans" }
        } label: {
            Label("Language", systemImage: "globe")
        }.font(.system(size: 12)).frame(minHeight: 44)
            .accessibilityIdentifier("setup-language")
    }

    private var versionLabel: some View {
        Text("StarPilot BT · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            .font(.system(size: 11)).foregroundStyle(muted)
    }

    private var preferencesHeading: some View {
        Text("PREFERENCES").font(.system(size: 11, weight: .medium)).tracking(1.2)
            .foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionExtras: some View {
        VStack(spacing: 8) {
            row("network", title: "Galaxy tunnel", subtitle: model.tunnel.credential == nil ? "Not set up" : model.tunnel.status) {
                Button(model.tunnel.credential == nil ? "Set up" : "Manage") { showTunnel = true }.accessibilityIdentifier("tunnel-setup")
            }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 16))
            DisclosureGroup(isExpanded: $advanced) { advancedControls.padding(.top, 8) } label: {
                Text("Advanced connection options").font(.system(size: 13)).frame(minHeight: 30)
            }.tint(accent).padding(.horizontal, 14).padding(.vertical, 7).background(panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.16)))
        }
    }

    private func openReconnectedGalaxy() {
        guard openAfterReconnect, !pairing, connected, model.opened else { return }
        openAfterReconnect = false
        select(.galaxy)
    }

    private func connectionPanel(extraSpacing: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 10 + extraSpacing) {
            HStack(spacing: 10) {
                Image(model.transport.label == "Tunnel" ? "ConnectionNetwork" : model.transport.label == "Local Wi-Fi" ? "ConnectionWiFi" : "ConnectionBluetooth").renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(accent)
                    .frame(width: 38, height: 38).background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your comma").font(.system(size: 17, weight: .medium))
                    Text(LocalizedStringKey(status)).font(.system(size: 11)).foregroundStyle(muted).accessibilityAddTraits(.updatesFrequently)
                }
                Spacer(minLength: 4)
                Text(LocalizedStringKey(pairing ? "Pairing…" : connected ? "Connected" : connecting ? "Connecting…" : "Offline"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(pairing ? accent : connected ? .mint : muted)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background((pairing ? accent : connected ? Color.mint : muted).opacity(0.13), in: Capsule())
            }
            HStack(spacing: 3) {
                ForEach([ConnectionMode.automatic, .bluetooth, .lan], id: \.self) { mode in
                    Button { model.mode = mode } label: {
                        Text(LocalizedStringKey(mode == .automatic ? "Automatic" : mode == .bluetooth ? "Bluetooth" : "Local Wi-Fi"))
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(model.mode == mode ? Color.white : Color.primary)
                            .background(model.mode == mode ? accent : Color.clear, in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
                }
            }.padding(3).background(accent.opacity(0.07), in: Capsule())
                .accessibilityLabel("Connection mode").disabled(pairing)
            if model.mode == .automatic {
                HStack {
                    Text(model.connectionPriority.map(\.title).joined(separator: " → ")).font(.system(size: 11)).foregroundStyle(muted)
                    Spacer()
                    Button("Set order") { showOrder = true }.font(.system(size: 12)).frame(minHeight: 32)
                }.disabled(pairing)
            }
            if !pairing {
                if model.pairingKey.isEmpty && !model.hasLANPairingSetup {
                    Text("Allow Local Network and Bluetooth when iPhone asks. We’ll find comma on your Wi-Fi or hotspot first.").font(.system(size: 11)).foregroundStyle(muted)
                }
                Text(LocalizedStringKey(model.mode == .automatic ? "Uses your first available connection" : model.mode == .bluetooth ? "Connect directly to comma\nControl Galaxy without Local Wi-Fi" : "Connect over your local network\nJoin the same Wi-Fi or comma’s hotspot"))
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
            }
            if needsPairing && !pairing && !connecting {
                if bluetooth.pairingRecoveryNeeded {
                    Text("We found comma, but couldn’t verify your saved pairing after repeated attempts. The pairing may have changed, or the connection may be interrupted.")
                        .font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
                }
                Text(model.hasLANPairingSetup
                     ? "1. Keep comma on and nearby.\n2. Join the same Wi-Fi as comma, or comma’s hotspot.\n3. Tap the button below. This app opens pairing on comma automatically, then connects over Bluetooth."
                     : "1. Join the same Wi-Fi as comma, or comma’s hotspot.\n2. Tap below and select your comma.\n3. Once Local Wi-Fi connects, select Bluetooth here to finish setup.")
                    .font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
            }
            if model.mode != .bluetooth && !connected && !pairing && (discovery.searching || !connectionCandidates.isEmpty) {
                discoveredCommas
            } else {
            Button {
                if connected && model.opened { select(.galaxy) }
                else if needsPairing {
                    if model.hasLANPairingSetup { model.pairWithComma() }
                    else { model.mode = .automatic; model.connect() }
                }
                else {
                    openAfterReconnect = true
                    model.connect()
                    openReconnectedGalaxy()
                }
            } label: {
                HStack(spacing: 7) {
                    if pairing { PairingSignal() }
                    else if connecting || (connected && !model.opened) { ProgressView().controlSize(.small) }
                    Text(LocalizedStringKey(pairing ? model.connectionMessage : primaryTitle))
                        .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(LinearGradient(colors: [Color(red: 0.73, green: 0.55, blue: 1), accent], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    .foregroundStyle(Color(red: 0.12, green: 0.06, blue: 0.19))
            }.buttonStyle(.plain).disabled(pairing || connecting || (connected && !model.opened))
            }
            if bluetooth.pairingRecoveryNeeded && model.mode == .bluetooth && !pairing && !connecting && !connected {
                Button("Try saved pairing once more") {
                    bluetooth.retrySavedPairing()
                    model.connect()
                }.font(.caption).frame(maxWidth: .infinity, minHeight: 44)
            }
            if pairing {
                Button("Cancel pairing") { model.cancelPairing() }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 30)
            } else if !model.pairingFailure.isEmpty {
                connectionMessage(model.pairingFailure)
            } else if model.connectionMessage != "Connected over \(model.transport.label)." && !connected {
                connectionMessage(model.connectionMessage)
            }
            if !pairing && (!model.pairingFailure.isEmpty || (bluetooth.connectionFailed && model.mode != .lan)) {
                Button("Bluetooth connection help") { showPairingHelp = true }
                    .font(.system(size: 11)).foregroundStyle(accent).frame(minHeight: 30)
            }
            if !pairing && !connecting && !connected {
                VStack(spacing: 4) {
                    Text("Still not working? Submit a log so we can investigate. Describe what happened and which steps you tried.")
                        .font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
                    Button(action: submitReport) {
                        Label("Submit connection log", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    Text("Review your report before sending. Includes the installed app build and a fresh diagnostic snapshot when you tap Send. Internet access is needed to send it.")
                        .font(.caption2).foregroundStyle(muted).multilineTextAlignment(.center)
                }
            }
        }.padding(14).background(LinearGradient(colors: [panel, background], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(accent.opacity(0.25)))
    }

    private func connectionMessage(_ text: String) -> some View {
        let copy = text
        let split = copy.range(of: ". ")
        let title = split.map { String(copy[..<$0.lowerBound]) } ?? copy
        let detail = split.map { String(copy[$0.upperBound...]) }
        return VStack(spacing: 4) {
            Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.9))
            if let detail, !detail.isEmpty {
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3)
            }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.top, 3)
    }

    private var discoveredCommas: some View {
        VStack(spacing: 8) {
            ForEach(connectionCandidates) { device in
                Button {
                    connectingCommaID = device.id
                    openAfterReconnect = true
                    Task { @MainActor in
                        defer { connectingCommaID = nil }
                        let selected = await model.selectDiscoveredComma(device)
                        if !selected && device.address == "172.31.254.1" {
                            openAfterReconnect = false
                            showHotspotJoin = true
                        } else if selected { openReconnectedGalaxy() }
                    }
                } label: {
                    HStack(spacing: 12) {
                        HStack(alignment: .bottom, spacing: 3) {
                            ForEach(0..<4) { bar in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(accent.opacity(0.45 + Double(bar) * 0.18))
                                    .frame(width: 4, height: CGFloat(7 + bar * 5))
                            }
                        }.frame(width: 28, height: 26).accessibilityHidden(true)
                        Text(device.name).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(device.address).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(muted).lineLimit(1)
                        if connectingCommaID == device.id {
                            ProgressView().controlSize(.small).tint(accent)
                        } else {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                        }
                    }.padding(.horizontal, 14).frame(minHeight: 58)
                        .background(LinearGradient(colors: [accent.opacity(0.18), panel], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.35)))
                        .overlay(alignment: .bottomLeading) {
                            if device.address == "172.31.254.1" {
                                Label("Comma Hotspot", systemImage: "wifi")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(accent)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(panel, in: Capsule())
                                    .padding(.leading, 14).offset(y: 7)
                            }
                        }
                        .padding(.bottom, device.address == "172.31.254.1" ? 7 : 0)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).disabled(model.selectingDiscoveredComma)
                    .accessibilityLabel("Connect to \(device.name), \(device.address)")
            }
            HStack(spacing: 8) {
                if discovery.searching { ProgressView().controlSize(.mini).tint(accent) }
                Text(discovery.searching ? "Finding comma on Local Wi-Fi…" : "Select your comma")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Button(discovery.searching ? "Stop" : "Search again") {
                    if discovery.searching { discovery.stop() } else { discovery.start() }
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
                    .frame(minHeight: 44).disabled(model.selectingDiscoveredComma)
            }
        }
    }

    private func preferences(extraSpacing: CGFloat = 0) -> some View {
        VStack(spacing: extraSpacing) {
            SentrySettingsView()
            separator
            row("music.note", title: "Phone music", subtitle: pairing ? "Waiting for app pairing" : audio.summary) {
                Button("Set up") { model.startAudioPairing() }.disabled(!connected || pairing).font(.system(size: 12)).frame(minHeight: 44)
            }
            separator
            row("location", title: "Share phone location", subtitle: location.status.isEmpty ? "Optional" : location.status) {
                Toggle("Share phone location", isOn: Binding(get: { location.sharing }, set: { location.setSharing($0) })).labelsHidden()
            }
            separator
            row("rectangle.on.rectangle", title: "Galaxy screens", subtitle: pairing ? "Waiting for pairing" : checking ? "Checking version…" : assets.status == "Galaxy matches comma." ? "Up to date · just checked" : assets.status.contains("screens have changed") ? "Update available · connect over Wi-Fi or Tunnel" : assets.readyRoot != nil ? "Saved from your comma" : "Not downloaded · needs Local Wi-Fi or Tunnel") {
                Button {
                    Task { await model.checkGalaxyUpdates(); checked = true }
                } label: {
                    if checking { ProgressView().controlSize(.small).accessibilityLabel("Checking Galaxy") }
                    else { Text(checked ? assets.readyRoot != nil ? "✓ Checked" : "Retry" : "Check") }
                }.font(.system(size: 12)).frame(minHeight: 44).disabled(checking || !connected || pairing)
            }
            if !checking && (checked || assets.status.contains("screens have changed") || assets.status.contains("Couldn’t check Galaxy screens")) { message(assets.status).padding(.horizontal, 14).padding(.bottom, 10) }
            separator
            row("ladybug", title: "Logs & support", subtitle: "Report a problem or share diagnostics") {
                Button { select(.logs) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Open Logs & support")
            }
            separator
            row("chevron.left.forwardslash.chevron.right", title: "Developer mode", subtitle: "Advanced testing") {
                Toggle("Developer mode", isOn: $model.developerMode).labelsHidden().accessibilityIdentifier("developer-mode-toggle")
            }
            if model.developerMode {
                Divider().overlay(accent.opacity(0.12)).padding(.leading, 42)
                row("location.fill", title: "Navigation alpha testing", subtitle: "Navigation UI and CarPlay maps · experimental") {
                    Toggle("Navigation alpha testing", isOn: Binding(get: { model.navigationAlpha }, set: { if $0 { confirmNavigationAlpha = true } else { model.navigationAlpha = false } })).labelsHidden()
                        .accessibilityIdentifier("navigation-alpha-toggle")
                }
            }
        }.background(panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.23)))
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Hide background location indicator", isOn: Binding(get: { hideLocationIndicator }, set: { hideLocationIndicator = $0; location.setHideBackgroundIndicator($0) }))
            Text("Requires Always location access. iOS may still show the indicator with While Using access.")
                .font(.system(size: 11)).foregroundStyle(muted)
            Divider()
            Toggle("Follow Galaxy language", isOn: $followGalaxyLanguage)
            Text("Use Galaxy’s selected language after connecting.")
                .font(.system(size: 11)).foregroundStyle(muted)
            Divider()
            if model.developerMode {
                row("bolt", title: "Fast Bluetooth reads", subtitle: bluetooth.fastReadFallback ? "Reliable reads active after an error" : "Experimental · turn off for reliable reads") {
                    Toggle("Fast Bluetooth reads", isOn: $bluetooth.fastReads).labelsHidden()
                }
                Divider()
            }
            if model.mode != .bluetooth {
                HStack {
                    Button(discovery.searching ? "Stop discovery" : "Find comma on Local Wi-Fi") {
                        if discovery.searching { discovery.stop() } else { discovery.start() }
                    }.disabled(model.selectingDiscoveredComma || pairing)
                }
                message(discovery.status)
                row("antenna.radiowaves.left.and.right", title: "Find address automatically", subtitle: "Discover comma’s address over Bluetooth") {
                    Toggle("Find address over Bluetooth", isOn: $model.findAddressAutomatically).labelsHidden()
                }
                TextField("Comma IP address", text: $model.address, prompt: Text("172.31.254.1 or IP:8082").foregroundColor(muted)).keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.plain)
                    .foregroundStyle(Color.primary).tint(accent).padding(12)
                    .background(background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.3)))
                message(lan.status)
            }
            if model.mode != .lan {
                Button(model.pairingKey.isEmpty ? "Pair Bluetooth with comma" : "Pair Bluetooth again") { model.pairWithComma() }.disabled(pairing || !model.hasLANPairingSetup)
                if !model.hasLANPairingSetup { message("Connect to comma over Local Wi-Fi before setting up Bluetooth.") }
                SecureField("64-character pairing key", text: $model.pairingKey, prompt: Text("64-character pairing key").foregroundColor(muted))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.plain)
                    .foregroundStyle(Color.primary).tint(accent).padding(12)
                    .background(background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.3)))
                Button(bluetooth.isScanning ? "Scanning…" : "Scan for comma") { model.wantsConnection = true; bluetooth.scan() }
                    .disabled(bluetooth.isScanning || bluetooth.connecting || pairing)
                message(bluetooth.status)
                ForEach(bluetooth.devices) { device in
                    Button(device.name) {
                        model.opened = false; model.wantsConnection = true; lan.clearEndpoint(); lan.bind(to: nil); model.address = ""
                        UserDefaults.standard.removeObject(forKey: "galaxy.comma.identity")
                        UserDefaults.standard.removeObject(forKey: "galaxy.lan.address")
                        bluetooth.connect(device, pairingKey: model.pairingKey)
                    }.disabled(bluetooth.connecting || pairing)
                }
                if bluetooth.connecting { Button("Cancel Bluetooth connection") { bluetooth.disconnect() } }
                Button("Forget Bluetooth pairing", role: .destructive) { confirmForget = true }.disabled(pairing)
            }
            message(assets.status)
            if let url = model.legacyURL { Text(url.absoluteString).font(.caption).textSelection(.enabled) }
            Button("Disconnect") { model.disconnect() }.disabled(pairing)
        }.font(.system(size: 13)).buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var separator: some View { Rectangle().fill(accent.opacity(0.12)).frame(height: 1).padding(.leading, 42) }
    private func message(_ text: String) -> some View {
        Text(LocalizedStringKey(text)).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
    }
    private func row<Control: View>(_ symbol: String, title: String, subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium))
                Text(LocalizedStringKey(subtitle)).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            control().fixedSize(horizontal: true, vertical: false)
        }.padding(.horizontal, 13).padding(.vertical, 6).frame(minHeight: 56)
    }
}

private struct PairingSignal: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { index in
                Capsule().frame(width: 3, height: CGFloat(5 + index * 4))
                    .opacity(reduceMotion || pulse ? 1 : 0.25)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true).delay(Double(index) * 0.15), value: pulse)
            }
        }.frame(height: 15).onAppear { pulse = true }.accessibilityHidden(true)
    }
}

private struct ConnectionOrbit: View {
    let route: String
    let pairing: Bool
    private let purple = Color(red: 0.68, green: 0.48, blue: 0.96)
    var body: some View {
        ZStack {
            Ellipse().stroke(purple.opacity(0.5), lineWidth: 1).frame(width: 232, height: 64).rotationEffect(.degrees(12)).position(x: 132, y: 48)
            Ellipse().stroke(purple.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                .frame(width: 258, height: 76).rotationEffect(.degrees(-9)).position(x: 132, y: 48)
            Image("StarPilotMark").resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.6)))
                .shadow(color: purple.opacity(0.5), radius: 16).frame(width: 60, height: 60).position(x: 132, y: 43)
            node("ConnectionWiFi", angle: 155, active: route == "Local Wi-Fi")
            node("ConnectionBluetooth", angle: 110, active: route == "Bluetooth" || pairing)
            node("ConnectionNetwork", angle: -25, active: route == "Tunnel")
        }.frame(width: 264, height: 88).accessibilityHidden(true)
    }
    private func node(_ symbol: String, angle: Double, active: Bool) -> some View {
        let theta = angle * .pi / 180, rotation = 12.0 * .pi / 180
        let x = 132 + 116 * cos(theta) * cos(rotation) - 32 * sin(theta) * sin(rotation)
        let y = 48 + 116 * cos(theta) * sin(rotation) + 32 * sin(theta) * cos(rotation)
        return Image(symbol).renderingMode(.template).resizable().scaledToFit().frame(width: 15, height: 15).foregroundStyle(active ? Color.white : Color.white.opacity(0.65))
            .frame(width: 30, height: 30).background(Color(red: 0.09, green: 0.075, blue: 0.15), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(active ? 0.75 : 0.4)))
            .shadow(color: purple.opacity(active ? 0.35 : 0), radius: 7).position(x: x, y: y)
    }
}


private struct TunnelSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @Sta…22921 tokens truncated…        Text("Report a problem through Discord to keep your logs and support replies together.")
                        .font(.subheadline).foregroundStyle(muted)
                    Button {
                        submitReport()
                    } label: {
                        Label("Report a problem on Discord", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .foregroundStyle(.white).background(accent, in: Capsule())
                    }.buttonStyle(.plain)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 22))
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        DisclosureGroup("View diagnostic logs") {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Report", selection: $log.section) {
                                    ForEach(["Connections", "Galaxy", "Live View"], id: \.self) { Text($0).tag($0) }
                                }.pickerStyle(.segmented)
                                HStack {
                                    Button(log.copied ? "Copied" : "Copy selected", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = selectedReport(); log.copied = true
                                    }
                                    Spacer()
                                    Button("Refresh", systemImage: "arrow.clockwise") { log.detail = previewReport(); log.copied = false }
                                }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                                Button("Copy all diagnostics", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = allReports(); log.copied = true
                                }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                                Text("Preview shows the latest 150 connection events. Copy or share includes the full retained log.")
                                .font(.caption).foregroundStyle(.secondary)
                                Text(log.detail)
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                                Button("Clear connection history") { log.clear(); log.detail = previewReport() }
                                .font(.caption).foregroundStyle(muted)
                            }
                        }.font(.subheadline).tint(muted)
                        Divider()
                        Button(exporting ? "Preparing report…" : "Export logs (.txt)") {
                            guard !exporting else { return }
                            exporting = true; exportStatus = ""
                            let report = allReports()
                            Task {
                                do {
                                    let url = try await Task.detached(priority: .utility) {
                                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                                        do {
                                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                            let name = "StarPilot-diagnostics-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".txt"
                                            let url = directory.appendingPathComponent(name)
                                            try report.write(to: url, atomically: true, encoding: .utf8)
                                            return url
                                        } catch {
                                            try? FileManager.default.removeItem(at: directory)
                                            throw error
                                        }
                                    }.value
                                    reportDirectory = url.deletingLastPathComponent()
                                    sharedReport = GalaxyDownloadedFile(url: url)
                                } catch { exportStatus = "Couldn’t prepare diagnostics. Try again or copy the report." }
                                exporting = false
                            }
                        }.buttonStyle(.plain).font(.footnote).foregroundStyle(muted)
                            .frame(minHeight: 44, alignment: .leading).disabled(exporting).accessibilityIdentifier("save-diagnostics-txt")
                        if !exportStatus.isEmpty { Text(exportStatus).font(.caption).foregroundStyle(.secondary) }
                        Text("For manual troubleshooting when needed.")
                            .font(.caption).foregroundStyle(muted)
                    }.padding(.top, 12)
                } label: {
                    Text("Troubleshooting").font(.subheadline).foregroundStyle(muted)
                }.tint(muted)
            }.padding(20)
        }.background(background.ignoresSafeArea())
            .sheet(item: $sharedReport, onDismiss: {
                if let directory = reportDirectory { try? FileManager.default.removeItem(at: directory) }
                reportDirectory = nil
            }) { file in
                GalaxyFileShareSheet(url: file.url) { sharedReport = nil }
            }
            .task {
                while !Task.isCancelled {
                    let report = previewReport()
                    if report != log.detail { log.detail = report }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onChange(of: log.section) { _, _ in log.detail = previewReport(); log.copied = false }
    }
}

/// The system owns placement and safe-area reservation, including Duo's side rail.
@available(iOS 27.1, *)
private struct AdaptiveCompanionChrome<Content: View>: View {
    @ObservedObject var model: AppModel
    let tab: CompanionTab
    let select: (CompanionTab) -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        NavigationStack {
            AdaptiveCompanionLayout(model: model, tab: tab, select: select, content: content)
        }
    }
}

private struct CompanionWebSafeArea: ViewModifier {
    @Environment(\.companionVerticalBar) private var verticalBar
    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: verticalBar ? [.top, .bottom] : .bottom)
    }
}

private struct CompanionVerticalBarKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var companionVerticalBar: Bool {
        get { self[CompanionVerticalBarKey.self] }
        set { self[CompanionVerticalBarKey.self] = newValue }
    }
}

@available(iOS 27.1, *)
private struct AdaptiveCompanionLayout<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @ObservedObject var model: AppModel
    let tab: CompanionTab
    let select: (CompanionTab) -> Void
    @ViewBuilder var content: () -> Content
    private var tabs: [CompanionTab] {
        model.navigationEnabled ? [.galaxy, .navigation, .connections] : [.galaxy, .connections]
    }
    var body: some View {
        content()
            .environment(\.companionVerticalBar, verticalEdge != nil)
            .toolbar {
                // Each action is a real toolbar item; the system owns its size and spacing.
                ToolbarItemGroup(placement: .topBarLeading) {
                    ForEach(tabs) { item in
                        Button { select(item) } label: {
                            Label(item.rawValue, systemImage: item.icon)
                        }
                        .tint(tab == item ? Color.purple : Color.primary)
                        .accessibilityIdentifier("main-tab-" + item.rawValue)
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                }.axisBehavior(.verticalPreferred)
                ToolbarItem(placement: .topBarTrailing) {
                    AdaptiveConnectionStatus(model: model, openSettings: { select(.connections) })
                }.axisBehavior(.verticalPreferred)
            }
            .toolbarVerticalBehavior(.automatic)
    }
}

@available(iOS 27.1, *)
private struct AdaptiveConnectionStatus: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    @State private var showingConnection = false
    var body: some View {
        CompactConnectionStatus(model: model, nativeToolbar: true) {
            showingConnection = true
        }
        .popover(isPresented: $showingConnection) {
            VStack(spacing: 12) {
                Text("Connection").font(.headline)
                CompactConnectionStatus(model: model) {
                    showingConnection = false
                    openSettings()
                }
                .fixedSize(horizontal: true, vertical: false)
                Button("Connection settings") {
                    showingConnection = false
                    openSettings()
                }
            }
            .padding(20)
            .fixedSize()
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// Fail closed: only the identified Duo hardware/simulator uses the experimental layout.
enum DuoLayout {
    static let isEnabled: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
        #else
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return identifier == "iPhone19,4"
        #endif
    }()
}
