import Foundation
import Combine

@MainActor
final class NavigationServices: ObservableObject {
    let connection: CommaConnection
    let navigation = NavigationModel()
    let saved = SavedPlacesStore()
    private var routeTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var phoneActive = false
    private var enabled = false
    private var carPlayActive = false
    private var resetting = false
    init(app: AppModel) {
        connection = CommaConnection(app: app)
        navigation.onEvent = { [weak app] in app?.connectionLog.record("Navigation: " + $0) }
        subscription = navigation.$navigating.combineLatest(navigation.$usingComma)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.sync() }
    }
    func resetNavigation() async {
        guard !resetting else { return }
        resetting = true
        let resetID = String(UUID().uuidString.prefix(8))
        connection.recordAction("USER RESET [\(resetID)] started; intentional route clearing and request cancellation follow")
        defer { resetting = false; navigation.busy = false; connection.busy = false }
        let identity = connection.deviceIdentity
        routeTask?.cancel(); routeTask = nil
        connection.invalidateNavigationRequests()
        navigation.resetLocalNavigation()
        navigation.busy = true
        connection.recordAction("Reset: cleared local navigation and invalidated pending results")
        guard let identity, connection.connected else {
            navigation.notice = "Phone navigation cleared. Comma is not verified; its route was left unchanged."
            connection.recordAction("USER RESET [\(resetID)] finished: phone cleared; comma unverified, no remote clear sent")
            return
        }
        do {
            guard try await connection.ensureDeviceIdentity() == identity else { throw BridgeError.message("Comma changed.") }
            _ = try await connection.navigation(.read)
            _ = try await connection.navigation(.end)
            navigation.notice = "Navigation cleared on phone and comma."
            connection.recordAction("USER RESET [\(resetID)] finished: phone and comma clear confirmed")
        } catch {
            navigation.error = "Phone navigation cleared. Comma did not confirm clearing its route; check its screen."
            connection.recordAction("USER RESET [\(resetID)] finished: phone cleared; comma clear failed: \(LANTransport.failureCode(error))")
        }
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value {
            routeTask?.cancel(); routeTask = nil
            connection.invalidateNavigationRequests()
            navigation.resetLocalNavigation()
        }
        sync()
    }
    func setCarPlayActive(_ active: Bool) { carPlayActive = active; sync() }
    func setPhoneActive(_ active: Bool) { phoneActive = active; sync() }
    private func sync() {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-route") { return }
#endif
        let active = enabled && (phoneActive || carPlayActive || navigation.navigating)
        navigation.setActive(active)
        connection.app.setNavigationActive(enabled && navigation.navigating)
        if active && freshnessTask == nil {
            freshnessTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.navigation.checkCommaFreshness()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        } else if !active { freshnessTask?.cancel(); freshnessTask = nil }
        if enabled && active && navigation.navigating && navigation.usingComma {
            if routeTask == nil { routeTask = Task { [weak self] in
                guard let self else { return }
                await navigation.monitorComma(connection: connection)
            } }
        } else { routeTask?.cancel(); routeTask = nil }
    }
}
