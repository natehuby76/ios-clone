import SwiftUI

@main
struct ReportEditorHarness: App {
    var body: some Scene {
        WindowGroup { ReportEditorHost() }
    }
}

private struct ReportEditorHost: View {
    @State private var showReport = false
    var body: some View {
        Button("Open report") { showReport = true }
            .sheet(isPresented: $showReport) {
                DiscordReportSheet(logs: "UI test diagnostics", captureLogs: { "UI test diagnostics" }, onSent: {})
            }
    }
}
