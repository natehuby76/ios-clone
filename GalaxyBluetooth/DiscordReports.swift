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

// Budget the encoded request, including JSON escaping, rather than character count.
enum DiagnosticReportBudget {
    static let maximumBytes = 16 * 1024 * 1024
    private static let datedEvent = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* "#)
    private static let benignStatus = try! NSRegularExpression(pattern:
        #"\b(?:fail(?:ed|ures?)?|errors?|disconnect(?:ed|s|ions?)?|cancel(?:led|ed|lations?)?|unavailable|unconfirmed|timeouts?)\s*=\s*(?:false|no|none|nil|null|0(?:\.0+)?)(?=$|[\s,;)\]}])"#,
        options: .caseInsensitive)
    private static let failureEvent = try! NSRegularExpression(pattern:
        #"fail|error|disconnect|cancel|unavailable|unconfirmed|did not verify|timeout|timed out|rejected|blocked|exhausted|no addresses|0 result\(s\)|(?:HTTP |→ )[45][0-9]{2}"#,
        options: .caseInsensitive)

    static func isFailure(_ event: String) -> Bool {
        // Successful requests include fields such as cancelled=false and failures=0.
        // Remove only benign assignments, so a separate error on the same line survives.
        let meaningful = benignStatus.stringByReplacingMatches(in: event, range: NSRange(event.startIndex..., in: event), withTemplate: "")
        return failureEvent.firstMatch(in: meaningful, range: NSRange(meaningful.startIndex..., in: meaningful)) != nil
    }

    static func fit(_ logs: String, maximumBytes: Int = maximumBytes) -> String {
        // Reserve room for description, reference, thread ID and JSON field names.
        let budget = max(0, maximumBytes - 64 * 1024)
        func fits(_ value: String) -> Bool {
            guard let data = try? JSONEncoder().encode(value) else { return false }
            return data.count <= budget
        }
        if fits(logs) { return logs }
        let lines = logs.components(separatedBy: "\n")
        let dated = lines.indices.filter {
            datedEvent.firstMatch(in: lines[$0], range: NSRange(lines[$0].startIndex..., in: lines[$0])) != nil
        }
        // Routine events go first; failures survive until routine history is exhausted.
        let failures = Set(dated.filter { isFailure(lines[$0]) })
        let ordered = dated.sorted { a, b in
            let af = failures.contains(a), bf = failures.contains(b)
            if af != bf { return !af }
            return lines[a] < lines[b]
        }
        func candidate(_ count: Int) -> String {
            let removed = Set(ordered.prefix(count))
            return "Upload size limit: omitted \(count) older events; routine events removed before failures.\n" + lines.indices.filter { !removed.contains($0) }.map { lines[$0] }.joined(separator: "\n")
        }
        var low = 0, high = ordered.count
        while low < high {
            let middle = (low + high) / 2
            if fits(candidate(middle)) { high = middle } else { low = middle + 1 }
        }
        let fitted = candidate(low)
        if fits(fitted) { return fitted }
        // Defensive fallback for an unusually large non-event snapshot.
        let characters = Array(fitted)
        low = 0; high = characters.count
        let notice = "Upload size limit: diagnostic snapshot shortened. Full capture is available under Troubleshooting → Export logs.\n"
        while low < high {
            let middle = (low + high + 1) / 2
            if fits(notice + String(characters.suffix(middle))) { low = middle } else { high = middle - 1 }
        }
        return notice + String(characters.suffix(low))
    }
}

enum SubmissionDiagnostics {
    static func capture(logs: () -> String, now: Date = Date(),
                        version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                        build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                        maximumBytes: Int = DiagnosticReportBudget.maximumBytes) -> String {
        let freshLogs = logs()
        guard !freshLogs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let distribution = freshLogs.components(separatedBy: "\n").first { $0.hasPrefix("Build distribution: ") }
            ?? "Build distribution: Unknown (not available in this capture)"
        let header = """
        StarPilot report submission
        Installed app at Send: \(version) (\(build))
        \(distribution)
        Captured at Send (UTC): \(ISO8601DateFormatter().string(from: now))
        Capture policy: fresh snapshot at first Send; retries preserve this snapshot.
        Event history may include earlier events from this app session.

        """
        // Keep submission provenance outside trimming, including the fallback path.
        return header + "\n" + DiagnosticReportBudget.fit(freshLogs, maximumBytes: maximumBytes - 2048)
    }
}

private struct PendingDiscordReport {
    let description: String
    let logs: String
    let reference: String
    let userID: String
    let created: Date
    var threadID: String? = nil

}

struct DiscordReportItem: Identifiable { let id: String; let title: String }

@MainActor
final class DiscordReports: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var busy = false
    @Published var connected = false
    @Published var status = ""
    @Published var threadURL: URL?
    @Published var reports: [DiscordReportItem] = []
    fileprivate var pendingReport: PendingDiscordReport?
    private var session: ASWebAuthenticationSession?
    private var credentials: DiscordCredentials?
    private let base = "https://starpilot-log-relay.nathan-g-hubbard.workers.dev"
    private let service = "link.galaxy.discord-reports"
    private let account = "oauth"
    override init() {
        super.init()
        // Migrate away from drafts saved by older versions.
        try? FileManager.default.removeItem(at: URL.applicationSupportDirectory.appendingPathComponent("PendingDiscordReport.json"))
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
            guard !logs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReportError("Diagnostics weren’t captured. Close this form and open Report a problem again.")
            }
            if credentials.expires.timeIntervalSinceNow < 60 {
                try store(await request("/auth/discord/refresh", body: ["refresh_token": credentials.refresh]))
                guard let updated = self.credentials else { return }; credentials = updated
            }
            let payload = ["description": description, "logs": logs, "reference": reference]
            guard try JSONSerialization.data(withJSONObject: payload).count <= DiagnosticReportBudget.maximumBytes else { throw ReportError("This report is too large. Use Troubleshooting → Export logs instead.") }
            if let pending = pendingReport {
                guard pending.reference == reference, pending.description == description, pending.logs == logs, pending.threadID == threadID else { throw ReportError("Reopen the report to retry the saved submission.") }
                guard pending.userID == credentials.userID else { throw ReportError("Reconnect the Discord account used for this report, or discard it first.") }
                guard pending.created.timeIntervalSinceNow > -6 * 24 * 3600 else { throw ReportError("This saved report is too old to retry safely. Check Discord, then discard it before starting another.") }
            } else {
                pendingReport = PendingDiscordReport(description: description, logs: logs, reference: reference, userID: credentials.userID, created: Date(), threadID: threadID)
            }
            var body = ["description": description, "logs": logs, "reference": reference]
            if let threadID { body["threadID"] = threadID }
            let response = try await request("/v1/logs", body: body, token: credentials.access)
            guard response["sent"] as? Bool == true, let raw = response["threadURL"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host == "discord.com", url.path.hasPrefix("/channels/") else {
                throw ReportError("Delivery wasn’t confirmed. Check Discord before sending another report.")
            }
            pendingReport = nil
            threadURL = url; status = "Report sent. Open the post to follow replies."
        } catch { status = error.localizedDescription }
    }
    private func request(_ path: String, body: [String: String], token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = path == "/v1/logs" ? 120 : 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard (request.httpBody?.count ?? 0) <= DiagnosticReportBudget.maximumBytes else { throw ReportError("This report is too large. Use Troubleshooting → Export logs instead.") }
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
        view.textColor = .label
        view.backgroundColor = .clear
        view.returnKeyType = .done
        view.enablesReturnKeyAutomatically = false
        view.accessibilityLabel = "Describe what happened"
        view.accessibilityIdentifier = "report-description"
        // No inputAccessoryView: Done belongs to the system keyboard itself.
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
        init(_ parent: ReportTextEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.isFocused = false }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true } // Multiline paste remains supported.
            parent.isFocused = false
            textView.resignFirstResponder()
            return false
        }
    }
}

struct DiscordReportSheet: View {
    @StateObject private var discord = DiscordReports()
    @Environment(\.colorScheme) private var colorScheme
    private let brandPurple = Color(red: 139.0 / 255, green: 92.0 / 255, blue: 246.0 / 255)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var visitEnded = false
    @State private var description = ""
    @State private var descriptionFocused = false
    @State private var attempted = false
    @State private var reference = UUID().uuidString
    let logs: String
    let captureLogs: () -> String
    let onSent: () -> Void
    @State private var showSendError = false
    @State private var sendError = ""
    @State private var restoredLogs: String?
    @State private var confirmDiscard = false
    @State private var explainDiscord = false
    @State private var selectedThread = ""
    @State private var showDestination = false
    @State private var sendAfterDestination = false
    @State private var loadedReports = false
    @State private var preparedLogs: String?
    private var reportLogs: String { restoredLogs ?? preparedLogs ?? logs }
    private var captureDetails: String {
        reportLogs.components(separatedBy: "\n").prefix(8).filter {
            $0.hasPrefix("Installed app at Send:") || $0.hasPrefix("Captured at Send (UTC):") || $0.hasPrefix("App:") || $0.hasSuffix("Z")
        }.joined(separator: " · ")
    }
    private func reloadReports() {
        Task { await discord.loadReports() }
    }
    private func loadReportsIfNeeded() {
        guard !discord.busy, discord.connected, !loadedReports else { return }
        loadedReports = true
        reloadReports()
    }
    private func prepareReport() {
        if preparedLogs == nil { preparedLogs = DiagnosticReportBudget.fit(logs) }
        loadReportsIfNeeded()
    }
    private func submitReport() {
        guard !discord.busy, !visitEnded, discord.connected else { return }
        if !attempted {
            restoredLogs = nil
            preparedLogs = SubmissionDiagnostics.capture(logs: captureLogs)
        }
        guard !reportLogs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            discord.status = "Diagnostics weren’t captured. Close this form and open Report a problem again."
            sendError = discord.status; showSendError = true
            return
        }
        let submissionLogs = reportLogs
        let submissionDescription = description
        let submissionReference = reference
        let submissionThread = selectedThread.isEmpty ? nil : selectedThread
        descriptionFocused = false; attempted = true
        Task {
            await discord.send(description: submissionDescription, logs: submissionLogs, reference: submissionReference, threadID: submissionThread)
            guard !visitEnded else { return }
            if discord.threadURL != nil {
                dismiss()
                onSent()
            } else {
                attempted = discord.pendingReport != nil
                sendError = discord.status
                showSendError = true
            }
        }
    }

    private var reportForm: some View {
        Form {
            Section {
                Label("StarPilot support", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.headline).foregroundStyle(brandPurple)
                Text("Tell us what happened. Your description goes to the support forum; diagnostics go to a private support channel.")
                Text("Your Discord username, description and a private-diagnostics link are visible in the forum. Only people with access to the private channel can open the diagnostics.").font(.footnote).foregroundStyle(.secondary)
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
            if attempted {
                Section("Current attempt — original diagnostics") {
                    Text(captureDetails).font(.footnote)
                    Text("Retry uses this attempt’s original description and logs. Closing this form or leaving the app clears the draft; your next report starts fresh.")
                    Button("Start new report with fresh logs") { confirmDiscard = true }.disabled(discord.busy)
                }
            }
            Section("What happened?") {
                ReportTextEditor(text: $description, isFocused: $descriptionFocused, editable: !attempted && !discord.busy)
                    .frame(height: 140)
                    .id("report-description")
                    .accessibilityLabel("Describe what happened")
                    .accessibilityIdentifier("report-description")
                Text("The post title is created from your description.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Review attached diagnostics") {
                    Text(String(reportLogs.prefix(24000))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if reportLogs.count > 24000 { Text("Preview shortened. The full diagnostics file will be attached.").font(.caption) }
                }
                Label("Diagnostics are always included", systemImage: "checkmark.circle.fill").disabled(attempted)
                if !attempted {
                    Text("Send captures fresh diagnostics and the installed app version. This preview will be refreshed when you send.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Diagnostics can include device names, local network addresses and connection or navigation status. Review the preview before sending.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if let url = discord.threadURL {
                    Link("Open in Discord", destination: url)
                } else if attempted {
                    Text("Use Retry to check or retry the original report.").font(.footnote).foregroundStyle(.secondary)
                }
                if attempted && discord.threadURL == nil {
                    Button("Start new report with fresh logs") { confirmDiscard = true }.disabled(discord.busy)
                }
                if !discord.status.isEmpty { Text(LocalizedStringKey(discord.status)).font(.callout).accessibilityIdentifier("discord-report-status") }
            }
        }
    }

    private var destinationSheet: some View {
        NavigationStack {
            Form {
                Section("Where should this report go?") {
                    Picker("Send to", selection: $selectedThread) {
                        Text("New thread").tag("")
                        ForEach(discord.reports) { report in Text(report.title).tag(report.id) }
                        if !selectedThread.isEmpty && !discord.reports.contains(where: { $0.id == selectedThread }) {
                            Text("Saved report thread").tag(selectedThread)
                        }
                    }.pickerStyle(.inline)
                    Button("Refresh your reports", systemImage: "arrow.clockwise") {
                                reloadReports()
                    }.disabled(discord.busy)
                    Text("Choose an existing thread for a follow-up, or start a new thread for a different problem. Older reports may not be listed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Choose report thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showDestination = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send report") {
                        sendAfterDestination = true
                        showDestination = false
                    }.disabled(discord.busy || !discord.connected)
                }
            }
        }.presentationDetents([.medium, .large])
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            reportForm.scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: descriptionFocused) { _, focused in
                    if focused {
                        withAnimation { scroll.scrollTo("report-description", anchor: .center) }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                    // Scroll again after the keyboard has reduced the form's visible
                    // height. A wrapped UITextView did not participate in Form focus.
                    if descriptionFocused {
                        withAnimation { scroll.scrollTo("report-description", anchor: .center) }
                    }
                }
                .listRowBackground(colorScheme == .dark ? Color(red: 0.09, green: 0.065, blue: 0.145) : Color(red: 0.91, green: 0.87, blue: 0.97))
                .buttonBorderShape(.capsule)
                .background(colorScheme == .dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.97, green: 0.95, blue: 0.99))
                .tint(brandPurple)
                .navigationTitle("Report a problem")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(discord.busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(discord.threadURL != nil ? "Done" : (attempted ? "Retry" : "Send")) {
                            if discord.threadURL != nil { dismiss() } else {
                                descriptionFocused = false
                                if attempted { submitReport() }
                                else { showDestination = true }
                            }
                        }.tint(.blue).disabled(discord.busy || (discord.threadURL == nil && (!discord.connected || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || description.count > 1000)))
                    }
                }
                .sheet(isPresented: $showDestination, onDismiss: {
                    guard sendAfterDestination else { return }
                    sendAfterDestination = false
                    submitReport()
                }) {
                    destinationSheet
                }
                .interactiveDismissDisabled(discord.busy)
                .alert("Report not confirmed", isPresented: $showSendError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(sendError)
                }
                .alert("Connect Discord", isPresented: $explainDiscord) {
                    Button("Continue") { discord.connect() }
                    Button("Not now", role: .cancel) {}
                } message: {
                    Text("Sign in to identify your report and open its support thread in Discord. Your diagnostics are only sent when you submit the report.")
                }
                .confirmationDialog("Start a new report? The previous report may already be in Discord. This captures fresh logs and creates a separate submission.", isPresented: $confirmDiscard, titleVisibility: .visible) {
                    Button("Start new report", role: .destructive) {
                        discord.pendingReport = nil
                        preparedLogs = DiagnosticReportBudget.fit(captureLogs())
                        attempted = false; restoredLogs = nil
                        reference = UUID().uuidString; discord.status = "Fresh diagnostics captured. Review and edit your description before sending."
                    }
                }
                .onChange(of: discord.busy) { _, busy in
                    if !busy { loadReportsIfNeeded() }
                }
                .onChange(of: discord.connected) { _, connected in
                    if !connected { loadedReports = false; if !attempted { selectedThread = "" } }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        sendAfterDestination = false
                        showDestination = false
                        visitEnded = true
                        discord.pendingReport = nil
                        dismiss()
                    }
                }
                .onAppear(perform: prepareReport)
            }
        }
    }
}
