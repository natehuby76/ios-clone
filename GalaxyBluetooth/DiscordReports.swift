import SwiftUI
import UIKit
import AuthenticationServices
import CryptoKit
import Security

private struct DiscordCredentials: Codable {
    let access: String
    let refresh: String
    let expires: Date
    let userID: String
}

private struct PendingDiscordReport: Codable {
    let description: String
    let logs: String
    let reference: String
    let userID: String
    let created: Date
    var threadID: String? = nil
    static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("PendingDiscordReport.json")
    }
    static func load() -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtection])
        var url = Self.url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

struct DiscordReportItem: Identifiable { let id: String; let title: String }

@MainActor
final class DiscordReports: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var busy = false
    @Published var connected = false
    @Published var status = ""
    @Published var threadURL: URL?
    @Published var reports: [DiscordReportItem] = []
    private var session: ASWebAuthenticationSession?
    private var credentials: DiscordCredentials?
    private let base = "https://starpilot-log-relay.nathan-g-hubbard.workers.dev"
    private let service = "link.galaxy.discord-reports"
    private let account = "oauth"
    override init() {
        super.init()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            credentials = try? JSONDecoder().decode(DiscordCredentials.self, from: data)
        }
        connected = credentials != nil
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func nonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ReportError("Couldn’t start secure sign-in.") }
        return Data(bytes).base64URL
    }
    func connect() {
        guard !busy else { return }
        busy = true; status = "Connecting to Discord…"
        do {
            let state = try nonce(), verifier = try nonce()
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
            var url = URLComponents(string: base + "/auth/discord/start")!
            url.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code_challenge", value: challenge)]
            session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "starpilot-discord") { [weak self] callback, error in
                Task { @MainActor in
                    guard let self else { return }
                    defer { self.busy = false; self.session = nil }
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        self.status = "Sign-in cancelled."; return
                    }
                    guard let callback, callback.scheme == "starpilot-discord", callback.host == "callback",
                          let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
                        self.status = "Couldn’t sign in. Try again."; return
                    }
                    func value(_ name: String) -> String? { parts.queryItems?.first(where: { $0.name == name })?.value }
                    guard value("state") == state, value("iss") == "https://discord.com", let code = value("code") else {
                        self.status = "Sign-in wasn’t completed. Try again."; return
                    }
                    do {
                        let response = try await self.request("/auth/discord/exchange", body: ["code": code, "verifier": verifier])
                        try self.store(response)
                        self.status = "Discord connected."
                    } catch { self.status = error.localizedDescription }
                }
            }
            session?.presentationContextProvider = self
            if session?.start() != true { busy = false; status = "Couldn’t open Discord sign-in."; session = nil }
        } catch { busy = false; status = error.localizedDescription }
    }
    private func store(_ response: [String: Any]) throws {
        guard let access = response["access_token"] as? String, let refresh = response["refresh_token"] as? String,
              let seconds = response["expires_in"] as? Double, let userID = response["user_id"] as? String else { throw ReportError("Discord returned an incomplete sign-in. Try again.") }
        let value = DiscordCredentials(access: access, refresh: refresh, expires: Date().addingTimeInterval(seconds), userID: userID)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw ReportError("Couldn’t securely save Discord sign-in.") }
        credentials = value; connected = true
    }
    func disconnect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        if let credentials {
            do { _ = try await request("/auth/discord/revoke", body: ["token": credentials.refresh]) }
            catch { status = "Couldn’t disconnect Discord. Try again when online."; return }
        }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        credentials = nil; connected = false; reports = []; status = "Discord disconnected."
    }
    func loadReports() async {
        guard !busy, var credentials else { return }
        busy = true; defer { busy = false }
        do {
            if credentials.expires.timeIntervalSinceNow < 60 {
                try store(await request("/auth/discord/refresh", body: ["refresh_token": credentials.refresh]))
                guard let updated = self.credentials else { return }; credentials = updated
            }
            let response = try await request("/v1/reports", body: [:], token: credentials.access)
            reports = (response["reports"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
                return DiscordReportItem(id: id, title: title)
            }
        } catch { status = error.localizedDescription }
    }
    func send(description: String, logs: String, reference: String, threadID: String? = nil) async {
        guard !busy, var credentials else { return }
        busy = true; status = "Sending report…"; threadURL = nil
        defer { busy = false }
        do {
            if credentials.expires.timeIntervalSinceNow < 60 {
                try store(await request("/auth/discord/refresh", body: ["refresh_token": credentials.refresh]))
                guard let updated = self.credentials else { return }; credentials = updated
            }
            let payload = ["description": description, "logs": logs, "reference": reference]
            guard try JSONSerialization.data(withJSONObject: payload).count <= 1024 * 1024 else { throw ReportError("This report is too large. Use Share diagnostics instead.") }
            if let pending = PendingDiscordReport.load() {
                guard pending.reference == reference, pending.description == description, pending.logs == logs, pending.threadID == threadID else { throw ReportError("Reopen the report to retry the saved submission.") }
                guard pending.userID == credentials.userID else { throw ReportError("Reconnect the Discord account used for this report, or discard it first.") }
                guard pending.created.timeIntervalSinceNow > -6 * 24 * 3600 else { throw ReportError("This saved report is too old to retry safely. Check Discord, then discard it before starting another.") }
            } else {
                try PendingDiscordReport(description: description, logs: logs, reference: reference, userID: credentials.userID, created: Date(), threadID: threadID).save()
            }
            var body = ["description": description, "logs": logs, "reference": reference]
            if let threadID { body["threadID"] = threadID }
            let response = try await request("/v1/logs", body: body, token: credentials.access)
            guard response["sent"] as? Bool == true, let raw = response["threadURL"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host == "discord.com", url.path.hasPrefix("/channels/") else {
                throw ReportError("Delivery wasn’t confirmed. Check Discord before sending another report.")
            }
            try? FileManager.default.removeItem(at: PendingDiscordReport.url)
            threadURL = url; status = "Report sent. Open the post to follow replies."
        } catch { status = error.localizedDescription }
    }
    private func request(_ path: String, body: [String: String], token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = path == "/v1/logs" ? 120 : 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard (request.httpBody?.count ?? 0) <= 1024 * 1024 else { throw ReportError("This report is too large. Use Share diagnostics instead.") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 401 { connected = false }
            throw ReportError(result["error"] as? String ?? "Couldn’t confirm delivery. Retry this report or check Discord.")
        }
        return result
    }
}
private struct ReportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
private extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private struct ReportTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let editable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.accessibilityLabel = "Describe what happened"
        let bar = UIToolbar()
        bar.sizeToFit()
        let hide = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: context.coordinator, action: #selector(Coordinator.hideKeyboard))
        hide.accessibilityLabel = "Hide keyboard"
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), hide]
        view.inputAccessoryView = bar
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.isEditable = editable
        if !isFocused && view.isFirstResponder { view.resignFirstResponder() }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReportTextEditor
        weak var textView: UITextView?
        init(_ parent: ReportTextEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { self.textView = textView; parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        @objc func hideKeyboard() { textView?.resignFirstResponder() }
    }
}

struct DiscordReportSheet: View {
    @StateObject private var discord = DiscordReports()
    @Environment(\.colorScheme) private var colorScheme
    private let brandPurple = Color(red: 139.0 / 255, green: 92.0 / 255, blue: 246.0 / 255)
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var descriptionFocused = false
    @State private var attempted = false
    @State private var reference = UUID().uuidString
    let logs: String
    @State private var restoredLogs: String?
    @State private var confirmDiscard = false
    @State private var explainDiscord = false
    @State private var selectedThread = ""
    @State private var loadedReports = false
    private var reportLogs: String { restoredLogs ?? logs }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("StarPilot support", systemImage: "bubble.left.and.text.bubble.right.fill")
                        .font(.headline).foregroundStyle(brandPurple)
                    Text("Tell us what happened. We’ll attach your diagnostics and open a post in Discord.")
                    Text("Your Discord username and report are visible to people with access to the forum.").font(.footnote).foregroundStyle(.secondary)
                    if discord.connected {
                        Label("Discord connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Button("Disconnect Discord", role: .destructive) { Task { await discord.disconnect() } }.disabled(discord.busy)
                    } else {
                        Button { explainDiscord = true } label: {
                            HStack(spacing: 10) {
                                Image("DiscordSymbol").resizable().scaledToFit().frame(width: 24, height: 18).accessibilityHidden(true)
                                Text("Connect Discord")
                            }
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent).disabled(discord.busy)
                    }
                }
                if discord.connected {
                    Section("Report") {
                        Picker("Send to", selection: $selectedThread) {
                            Text("New report").tag("")
                            ForEach(discord.reports) { report in Text(report.title).tag(report.id) }
                        }.disabled(attempted)
                        Button("Refresh your reports", systemImage: "arrow.clockwise") { Task { await discord.loadReports() } }.disabled(discord.busy || attempted)
                        Text("Report titles and thread IDs are saved with your Discord account so you can follow up. Older reports may not be listed.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("What happened?") {
                    ReportTextEditor(text: $description, isFocused: $descriptionFocused, editable: !attempted)
                        .frame(minHeight: 120)
                        .accessibilityLabel("Describe what happened")
                    Text("The post title is created from your description.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Review attached diagnostics") {
                        Text(String(reportLogs.prefix(24000))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if reportLogs.count > 24000 { Text("Preview shortened. The full diagnostics file will be attached.").font(.caption) }
                    }
                    Label("Diagnostics are always included", systemImage: "checkmark.circle.fill").disabled(attempted)
                    Text("Diagnostics can include device names, local network addresses and connection or navigation status. Review the preview before sending.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if let url = discord.threadURL {
                        Link("Open in Discord", destination: url)
                    } else if attempted {
                        Text("Use Send to check or retry this report.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if attempted && discord.threadURL == nil {
                        Button("Discard saved report", role: .destructive) { confirmDiscard = true }.disabled(discord.busy)
                    }
                    if !discord.status.isEmpty { Text(discord.status).font(.callout).accessibilityIdentifier("discord-report-status") }
                }
            }.scrollContentBackground(.hidden)
                .listRowBackground(colorScheme == .dark ? Color(red: 0.09, green: 0.065, blue: 0.145) : Color(red: 0.91, green: 0.87, blue: 0.97))
                .buttonBorderShape(.capsule)
                .background(colorScheme == .dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.97, green: 0.95, blue: 0.99))
                .tint(brandPurple)
                .navigationTitle("Report a problem")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(discord.busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(discord.threadURL != nil ? "Done" : "Send") {
                            if discord.threadURL != nil { dismiss() } else {
                                descriptionFocused = false; attempted = true
                                Task { await discord.send(description: description, logs: reportLogs, reference: reference, threadID: selectedThread.isEmpty ? nil : selectedThread) }
                            }
                        }.tint(.blue).disabled(discord.busy || (discord.threadURL == nil && (!discord.connected || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || description.count > 1000)))
                    }
                }
                .interactiveDismissDisabled(discord.busy)
                .alert("Connect Discord", isPresented: $explainDiscord) {
                    Button("Continue") { discord.connect() }
                    Button("Not now", role: .cancel) {}
                } message: {
                    Text("Sign in to identify your report and open its support thread in Discord. Your diagnostics are only sent when you submit the report.")
                }
                .confirmationDialog("Discard this saved report? Check Discord first—it may already have been delivered.", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Discard saved report", role: .destructive) {
                        do {
                            if FileManager.default.fileExists(atPath: PendingDiscordReport.url.path) {
                                try FileManager.default.removeItem(at: PendingDiscordReport.url)
                            }
                            attempted = false; description = ""; restoredLogs = nil
                            reference = UUID().uuidString; discord.status = ""
                        } catch { discord.status = "Couldn’t discard the saved report. Try again." }
                    }
                }
                .onChange(of: discord.busy) { _, busy in
                    if !busy && discord.connected && !loadedReports { loadedReports = true; Task { await discord.loadReports() } }
                }
                .onChange(of: discord.connected) { _, connected in
                    if !connected { loadedReports = false; selectedThread = "" }
                }
                .onAppear {
                    if discord.connected { loadedReports = true; Task { await discord.loadReports() } }
                    if let pending = PendingDiscordReport.load() {
                        description = pending.description; restoredLogs = pending.logs; selectedThread = pending.threadID ?? ""
                        reference = pending.reference; attempted = true
                        discord.status = "Your previous report is awaiting confirmation. Retry to check its delivery without creating a duplicate."
                    }
                }
        }
    }
}
