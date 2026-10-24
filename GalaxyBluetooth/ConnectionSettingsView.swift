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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var showOrder = false
    @State private var showTunnel = false
    @State private var advanced = false
    @State private var confirmForget = false
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
    private var needsPairing: Bool { model.mode == .bluetooth && model.pairingKey.isEmpty }
    private var connecting: Bool { !connected && (bluetooth.connecting || bluetooth.isScanning) }
    private var primaryTitle: String {
        if pairing { return "Pairing…" }
        if connected { return model.opened ? "Open Galaxy" : "Preparing Galaxy…" }
        if connecting { return "Connecting…" }
        return needsPairing ? (model.hasLANPairingSetup ? "Pair with comma" : "Connect over Local Wi-Fi first") : "Connect"
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

    init(model: AppModel, returningFromGalaxy: Bool, select: @escaping (CompanionTab) -> Void) {
        self.model = model; self.returningFromGalaxy = returningFromGalaxy; self.select = select
        bluetooth = model.bluetooth; lan = model.lan; assets = model.assets; server = model.server
        discovery = model.discovery; location = model.phoneLocation; audio = model.audioPairing
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
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
                ConnectionOrbit(route: connected ? model.transport.label : "", pairing: pairing)
                    .padding(.bottom, 10)
                connectionPanel
                Text("PREFERENCES").font(.system(size: 11, weight: .medium)).tracking(1.2)
                    .foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading)
                preferences
                row("network", title: "Galaxy tunnel", subtitle: model.tunnel.status) {
                    Button(model.tunnel.credential == nil ? "Set up" : "Manage") { showTunnel = true }
                }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 16))
                DisclosureGroup(isExpanded: $advanced) { advancedControls.padding(.top, 8) } label: {
                    Text("Advanced connection options").font(.system(size: 13)).frame(minHeight: 30)
                }.tint(accent).padding(.horizontal, 14).padding(.vertical, 7).background(panel, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.16)))
                HStack(spacing: 18) {
                    Button(model.loadingLegacyURL ? "Getting link…" : "Legacy Galaxy") {
                        Task { if let url = await model.fetchLegacyURL() {
                            openURL(url) { accepted in if !accepted { model.legacyMessage = "Couldn’t open your browser. Try again." } }
                        } }
                    }.disabled(model.loadingLegacyURL || pairing)
                    Link("Support", destination: URL(string: "https://wiki.firestar.link/ticketsystem/")!)
                    Link("Privacy", destination: URL(string: "https://github.com/natehuby76/ios-clone/blob/codex/secretgood-galaxy/docs/privacy.md")!)
                }.font(.system(size: 12)).frame(minHeight: 44)
                if !model.legacyMessage.isEmpty { message(model.legacyMessage) }
                if !server.error.isEmpty { message(server.error) }
                Text("StarPilot BT · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }.padding(.horizontal, 18).padding(.top, 0).padding(.bottom, 12)
                .frame(maxWidth: 460).frame(maxWidth: .infinity)
        }.scrollBounceBehavior(.basedOnSize).background {
            if model.navigationEnabled { LinearGradient(colors: [background, panel.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea() }
            else { background.ignoresSafeArea() }
        }.foregroundStyle(Color.primary).preferredColorScheme(model.navigationEnabled ? nil : .dark)
            .onChange(of: connected) { _, _ in openReconnectedGalaxy() }
            .onChange(of: pairing) { _, value in if value { openAfterReconnect = false } }
            .onChange(of: model.opened) { _, _ in openReconnectedGalaxy() }
            .onChange(of: model.wantsConnection) { _, value in if !value { openAfterReconnect = false } }
            .sheet(isPresented: $showOrder) {
                NavigationStack {
                    List {
                        Section {
                            ForEach(model.connectionPriority) { route in
                                Label { Text(route.title) } icon: {
                                    if route == .tunnel { Image(systemName: "network") }
                                    else { Image(route == .lan ? "ConnectionWiFi" : "ConnectionBluetooth").renderingMode(.template).resizable().scaledToFit().frame(width: 22, height: 22) }
                                }
                            }.onMove { from, to in model.connectionPriority.move(fromOffsets: from, toOffset: to) }
                        } footer: { Text("Automatic uses the first available connection. Drag to change the order. Local Wi-Fi-only and Bluetooth-only ignore this order.") }
                        Button("Reset order") { model.connectionPriority = ConnectionRoute.allCases }
                    }.environment(\.editMode, .constant(.active))
                        .navigationTitle("Connection order").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showOrder = false } } }
                }.presentationDetents([.medium])
            }
            .sheet(isPresented: $showTunnel) { TunnelSetupView(model: model) }
            .tint(accent)
            .alert("Join comma’s hotspot", isPresented: $showHotspotJoin) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This hotspot address is available in the device list, but your iPhone couldn’t reach and verify comma there. In iPhone Settings → Wi-Fi, join comma’s TheGalaxy-… network using the hotspot password shown on comma. Then return here and tap the comma row again.")
            }
            .alert("Reset Bluetooth pairing", isPresented: $showPairingHelp) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("If Bluetooth still won’t connect, try a fresh pairing:\n\n1. In this app, open Advanced → Forget Bluetooth pairing.\n2. On comma, open Bluetooth settings and forget this iPhone. Remove its app pairing too if it is listed separately.\n3. On iPhone, open Settings → Bluetooth → ⓘ beside comma → Forget This Device, if listed.\n4. Connect to comma over Local Wi-Fi, then start Bluetooth setup in this app. The app opens pairing on comma automatically.\n\nThis resets device pairing, not the app’s Bluetooth permission.")
            }
            .confirmationDialog("Forget Bluetooth pairing?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget pairing", role: .destructive) {
                    model.disconnect(); bluetooth.forgetSavedDevice(); PairingKeyStore.remove(); model.pairingKey = ""
                    lan.bind(to: nil); UserDefaults.standard.removeObject(forKey: "galaxy.comma.identity")
                }
            } message: { Text("This removes the saved app pairing. Pair your phone again to reconnect.") }
    }

    private func openReconnectedGalaxy() {
        guard openAfterReconnect, !pairing, connected, model.opened else { return }
        openAfterReconnect = false
        select(.galaxy)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(model.transport.label == "Tunnel" ? "ConnectionNetwork" : model.transport.label == "Local Wi-Fi" ? "ConnectionWiFi" : "ConnectionBluetooth").renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20).foregroundStyle(accent)
                    .frame(width: 38, height: 38).background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your comma").font(.system(size: 17, weight: .medium))
                    Text(status).font(.system(size: 11)).foregroundStyle(muted).accessibilityAddTraits(.updatesFrequently)
                }
                Spacer(minLength: 4)
                Text(pairing ? "Pairing…" : connected ? "Connected" : connecting ? "Connecting…" : "Offline")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(pairing ? accent : connected ? .mint : muted)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background((pairing ? accent : connected ? Color.mint : muted).opacity(0.13), in: Capsule())
            }
            HStack(spacing: 3) {
                ForEach([ConnectionMode.automatic, .bluetooth, .lan], id: \.self) { mode in
                    Button { model.mode = mode } label: {
                        Text(mode == .automatic ? "Automatic" : mode == .bluetooth ? "Bluetooth" : "Local Wi-Fi")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 36)
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
                Text(model.mode == .automatic ? "Uses your first available connection" : model.mode == .bluetooth ? "Connect directly to comma\nControl Galaxy without Local Wi-Fi" : "Connect over your local network\nJoin the same Wi-Fi or comma’s hotspot")
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(3)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
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
                    Text(pairing ? model.connectionMessage : primaryTitle)
                        .lineLimit(2).minimumScaleFactor(0.85).multilineTextAlignment(.center)
                }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(LinearGradient(colors: [Color(red: 0.73, green: 0.55, blue: 1), accent], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    .foregroundStyle(Color(red: 0.12, green: 0.06, blue: 0.19))
            }.buttonStyle(.plain).disabled(pairing || connecting || (connected && !model.opened))
            }
            if pairing {
                Button("Cancel pairing") { model.cancelPairing() }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 30)
            } else if !model.pairingFailure.isEmpty {
                connectionMessage(model.pairingFailure)
            } else if model.connectionMessage != "Connected over \(model.transport.label)." && !connected {
                connectionMessage(model.connectionMessage)
            }
            if !pairing && (!model.pairingFailure.isEmpty || (bluetooth.connectionFailed && model.mode != .lan)) {
                Button("Bluetooth trouble? Try resetting pairing") { showPairingHelp = true }
                    .font(.system(size: 11)).foregroundStyle(accent).frame(minHeight: 30)
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
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.9))
            if let detail, !detail.isEmpty {
                Text(detail)
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

    private var preferences: some View {
        VStack(spacing: 0) {
            row("music.note", title: "Phone music", subtitle: pairing ? "Waiting for app pairing" : audio.summary) {
                Button("Set up") { model.startAudioPairing() }.disabled(!connected || pairing).font(.system(size: 12)).frame(minHeight: 44)
            }
            separator
            row("location", title: "Share phone location", subtitle: location.status.isEmpty ? "Optional" : location.status) {
                Toggle("Share phone location", isOn: Binding(get: { location.sharing }, set: { location.setSharing($0) })).labelsHidden()
            }
            separator
            row("rectangle.on.rectangle", title: "Galaxy screens", subtitle: pairing ? "Waiting for pairing" : checking ? "Checking version…" : checked && assets.readyRoot != nil ? "Up to date · just checked" : assets.readyRoot != nil ? "Saved from your comma" : "Not downloaded · needs Local Wi-Fi or Tunnel") {
                Button {
                    Task { await model.checkGalaxyUpdates(); checked = true }
                } label: {
                    if checking { ProgressView().controlSize(.small).accessibilityLabel("Checking Galaxy") }
                    else { Text(checked ? assets.readyRoot != nil ? "✓ Checked" : "Retry" : "Check") }
                }.font(.system(size: 12)).frame(minHeight: 44).disabled(checking || !connected || !model.transport.usesNetwork || pairing)
            }
            if checked && !checking { message(assets.status).padding(.horizontal, 14).padding(.bottom, 10) }
            separator
            row("chevron.left.forwardslash.chevron.right", title: "Developer mode", subtitle: "Diagnostics and logs") {
                Toggle("Developer mode", isOn: $model.developerMode).labelsHidden().accessibilityIdentifier("developer-mode-toggle")
            }
            if model.developerMode {
                Divider().overlay(accent.opacity(0.12)).padding(.leading, 42)
                row("location.fill", title: "Navigation alpha testing", subtitle: "Navigation UI and CarPlay maps · experimental") {
                    Toggle("Navigation alpha testing", isOn: $model.navigationAlpha).labelsHidden()
                        .accessibilityIdentifier("navigation-alpha-toggle")
                }
            }
        }.background(panel, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.23)))
    }

    private var advancedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.developerMode {
                Toggle("Fast Bluetooth reads", isOn: $bluetooth.fastReads)
                message(bluetooth.fastReadFallback ? "Fast reads paused after an error. Reliable reads are active." : "Experimental. Turn off to use reliable reads.")
                Button("Open Dev / Logs") { select(.logs) }
                Divider()
            }
            if model.mode != .bluetooth {
                HStack {
                    Button(discovery.searching ? "Stop discovery" : "Find comma on Local Wi-Fi") {
                        if discovery.searching { discovery.stop() } else { discovery.start() }
                    }.disabled(model.selectingDiscoveredComma || pairing)
                }
                message(discovery.status)
                Toggle("Find address over Bluetooth", isOn: $model.findAddressAutomatically)
                TextField("Comma IP address", text: $model.address, prompt: Text("172.31.254.1 or IP:8082").foregroundColor(muted)).keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.plain)
                    .foregroundStyle(Color.white).tint(accent).padding(12)
                    .background(background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.3)))
                message(lan.status)
            }
            if model.mode != .lan {
                Button(model.pairingKey.isEmpty ? "Pair Bluetooth with comma" : "Pair Bluetooth again") { model.pairWithComma() }.disabled(pairing || !model.hasLANPairingSetup)
                if !model.hasLANPairingSetup { message("Connect to comma over Local Wi-Fi before setting up Bluetooth.") }
                SecureField("64-character pairing key", text: $model.pairingKey, prompt: Text("64-character pairing key").foregroundColor(muted))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.plain)
                    .foregroundStyle(Color.white).tint(accent).padding(12)
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
        Text(text).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
    }
    private func row<Control: View>(_ symbol: String, title: String, subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
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
    @State private var loginURL: URL?
    @State private var showScanner = false
    @State private var error = ""
    @State private var saving = false
    @State private var loginTask: Task<Void, Never>?
    @State private var store = WKWebsiteDataStore.nonPersistent()
    private static func validCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.name == "galaxy_session", cookie.isSecure else { return false }
        guard cookie.domain == "galaxy.firestar.link" || cookie.domain == ".galaxy.firestar.link" else { return false }
        return cookie.expiresDate.map { $0 > Date() } ?? true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let loginURL {
                    TunnelLoginView(url: loginURL, store: store)
                    Text("Sign in above, then tap Use tunnel. Enter your Galaxy password on this page. The app remembers your sign-in, not your password.").font(.footnote).padding(.horizontal)
                    Button(saving ? "Verifying…" : "Use tunnel") {
                        saving = true; error = ""
                        loginTask = Task { @MainActor in
                            defer { saving = false }
                            let cookies = await store.httpCookieStore.allCookies()
                            guard let cookie = cookies.first(where: Self.validCookie) else {
                                error = "Finish signing in to Galaxy first."; return
                            }
                            do {
                                try await model.acceptTunnel(url: loginURL, cookie: cookie.value)
                                try Task.checkCancellation()
                                dismiss()
                            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        }
                    }.buttonStyle(.borderedProminent).disabled(saving).padding(.bottom)
                } else {
                    Form {
                        Section {
                            TextField("https://galaxy.firestar.link/…", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            Button {
                                Task { @MainActor in
                                    guard DataScannerViewController.isSupported else { error = "QR scanning isn’t supported on this device. Paste your Galaxy link instead."; return }
                                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                                    guard allowed else { error = "Allow camera access in iPhone Settings to scan, or paste your Galaxy link instead."; return }
                                    guard DataScannerViewController.isAvailable else { error = "Camera unavailable. Try again or paste your Galaxy link."; return }
                                    error = ""; showScanner = true
                                }
                            } label: { Label("Scan comma’s QR code", systemImage: "qrcode.viewfinder") }
                            Button("Sign in") {
                                guard let url = TunnelTransport.endpoint(address) else { error = "Paste your full Galaxy link, including its 16-character code."; return }
                                error = ""; loginURL = url
                            }
                            if model.transport.connected {
                                Button("Get link from comma") {
                                    Task { if let url = await model.fetchLegacyURL() { address = url.absoluteString } else { error = model.legacyMessage } }
                                }
                            }
                        } header: { Text("Your Galaxy link") } footer: { Text("Scan the Galaxy QR code on comma or paste its private link, then sign in with your Galaxy password. Both phone and comma need internet for Tunnel. Automatic uses your saved connection order.") }
                        if model.tunnel.credential != nil {
                            Section { Button("Forget saved tunnel", role: .destructive) { model.forgetTunnel(); address = "" } }
                        }
                    }
                }
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red).padding() }
            }.navigationTitle("Galaxy tunnel").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .sheet(isPresented: $showScanner) {
                    NavigationStack {
                        TunnelQRScanner { value in
                            guard let url = TunnelTransport.endpoint(value) else {
                                error = "That isn’t a Galaxy tunnel link. Scan the Galaxy link QR code on comma."; showScanner = false; return
                            }
                            address = url.absoluteString; error = ""; showScanner = false; loginURL = url
                        } failed: { message in error = message; showScanner = false }
                        .navigationTitle("Scan Galaxy link").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showScanner = false } } }
                    }
                }
                .onAppear { address = model.tunnel.credential?.url ?? "" }
                .onDisappear { loginTask?.cancel() }
        }
    }
}

private struct TunnelLoginView: UIViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, url.scheme == "https", url.host == "galaxy.firestar.link",
                  url.port == nil, url.user == nil, url.password == nil else { decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
    }
}

private struct TunnelQRScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.finished else { return }
        do { try scanner.startScanning() }
        catch { context.coordinator.finish(error: "Couldn’t start the camera. Try again or paste your Galaxy link.") }
    }
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: TunnelQRScanner
        var finished = false
        init(parent: TunnelQRScanner) { self.parent = parent }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    finished = true; scanner.stopScanning(); parent.scanned(value); return
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            finish(error: "Camera unavailable. Try again or paste your Galaxy link.")
        }
        func finish(error: String) {
            guard !finished else { return }; finished = true
            DispatchQueue.main.async { self.parent.failed(error) }
        }
    }
}
