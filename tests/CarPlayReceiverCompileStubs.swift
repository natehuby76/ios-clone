// Compile only the changed video/transport on GitHub's iOS 26 SDK. The complete
// app requires iOS 27.1 SDK toolbar APIs and is archived separately by Xcode Cloud.
import Foundation
enum BridgeError: Error { case message(String) }
@MainActor final class AppModel {
    static let shared = AppModel()
    let lan = LANTransport()
}
@MainActor final class LANTransport {
    var connected = false
    var endpoint: URL?
    var generation = ""
    var verifiedDeviceID: String?
    static func failureCode(_ error: Error) -> String { String(describing: error) }
}
@MainActor final class CarPlayLiveDiagnostics {
    static let shared = CarPlayLiveDiagnostics()
    func record(_ message: String, includeInConnectionLog: Bool = true) {}
}
