import CarPlay
import UIKit
import CoreFoundation

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate {
    private var controller: CPInterfaceController?
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var overview: CPGridTemplate?
    private var temperatures: CPGridTemplate?
    private var rates: CPGridTemplate?
    private var toggles: CPGridTemplate?
    private var catalogue: [[String: Any]] = []
    private var values: [String: Any] = [:]
    private var categoryPage = 0
    private var busy = false
    private final class MetricPageState {
        let title: String
        let kind: String
        var index = 0
        init(title: String, kind: String) { self.title = title; self.kind = kind }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        overview = grid("StarPilot", icon: "car.side")
        temperatures = grid("Temperatures", icon: "thermometer.medium")
        rates = grid("Rates", icon: "speedometer")
        toggles = grid("Galaxy toggles", icon: "switch.2")
        guard let overview, let temperatures, let rates, let toggles else { return }
        let tabs = CPTabBarTemplate(templates: [overview, temperatures, rates, toggles])
        tabs.delegate = self
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        let model = AppModel.shared
        model.setCarPlayActive(true)
        refreshTelemetry()
        toggles.updateGridButtons([button("Load Galaxy menus", icon: "arrow.clockwise") { [weak self] in self?.loadGalaxy() }])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTelemetry() }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        timer?.invalidate(); timer = nil
        work?.cancel(); work = nil
        controller = nil
        overview = nil; temperatures = nil; rates = nil; toggles = nil
        catalogue = []; values = [:]; busy = false
        AppModel.shared.setCarPlayActive(false)
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if selectedTemplate === toggles { loadGalaxy() }
    }

    private func grid(_ title: String, icon: String) -> CPGridTemplate {
        let template = CPGridTemplate(title: title, gridButtons: [])
        template.tabTitle = title == "Galaxy toggles" ? "Toggles" : title
        template.tabImage = UIImage(systemName: icon)
        return template
    }

    private func button(_ title: String, icon: String, value: String? = nil, action: @escaping () -> Void = {}) -> CPGridButton {
        let image: UIImage
        if let value {
            image = UIGraphicsImageRenderer(size: CGSize(width: 110, height: 70)).image { _ in
                let text = String(value.prefix(18)) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold),
                    .foregroundColor: UIColor.systemPurple,
                    .paragraphStyle: {
                        let style = NSMutableParagraphStyle(); style.alignment = .center; return style
                    }()
                ]
                text.draw(in: CGRect(x: 0, y: 20, width: 110, height: 45), withAttributes: attributes)
            }
        } else {
            image = UIImage(systemName: icon) ?? UIImage(systemName: "circle")!
        }
        return CPGridButton(titleVariants: [title], image: image) { _ in action() }
    }

    private func external(_ metric: DiagnosticMetric) -> Bool {
        let name = metric.name.lowercased()
        return name.contains("external gpu") || name.contains("chestnut") || name.hasPrefix("sensor: amdgpu")
    }

    private func thermalGroup(_ metric: DiagnosticMetric) -> String {
        let name = metric.name.lowercased()
        if external(metric) { return "External GPU" }
        if name.hasPrefix("sensor:") { return "Other sensors" }
        if name.contains("cpu") || name.contains("dsp") || name.contains("soc") { return "Processors" }
        if name.contains("gpu") { return "Onboard GPU" }
        if name.contains("memory") { return "Memory" }
        if name.contains("intake") || name.contains("exhaust") { return "Cooling" }
        if name.contains("pmic") { return "Power" }
        if name.contains("modem") || name.contains("gnss") { return "Connectivity" }
        return "Other sensors"
    }

    private func maximum(_ metrics: [DiagnosticMetric]) -> String {
        guard let value = metrics.compactMap(\.value).filter(\.isFinite).max() else { return "—" }
        return String(format: "%.1f °C", value)
    }

    private func refreshTelemetry() {
        let model = AppModel.shared
        let diagnostics = model.diagnostics
        let sample = diagnostics.fresh ? diagnostics.snapshot : nil
        let temps = sample?.temperatures ?? []
        let updates = sample?.rates ?? []
        func rate(_ name: String) -> String {
            updates.first { $0.name.lowercased() == name.lowercased() }?.display ?? "—"
        }
        overview?.updateGridButtons([
            button("Connection", icon: "antenna.radiowaves.left.and.right", value: model.transport.connected ? model.transport.label : "Offline") { [weak self] in
                self?.notice(diagnostics.fresh ? "Telemetry connected." : diagnostics.status)
            },
            button("Driving status", icon: "car.side", value: sample?.engaged.map { $0 ? "Engaged" : "Inactive" } ?? "—"),
            button("CPU / DSP", icon: "cpu", value: maximum(temps.filter { thermalGroup($0) == "Processors" })),
            button("Onboard GPU", icon: "cpu", value: maximum(temps.filter { thermalGroup($0) == "Onboard GPU" })),
            button("Memory", icon: "memorychip", value: maximum(temps.filter { thermalGroup($0) == "Memory" })),
            button("Display FPS", icon: "display", value: rate("UI")),
            button("Model FPS", icon: "speedometer", value: rate("modelV2")),
            button("External GPU", icon: "cpu", value: maximum(temps.filter(external)))
        ])
        let groups = ["Processors", "Onboard GPU", "Memory", "Cooling", "Power", "Connectivity", "External GPU", "Other sensors"]
        temperatures?.updateGridButtons(groups.map { group in
            button(group, icon: "thermometer.medium", value: maximum(temps.filter { thermalGroup($0) == group })) { [weak self] in
                self?.showMetrics(group, kind: group)
            }
        })
        rates?.updateGridButtons([
            button("Camera FPS", icon: "camera", value: "\(updates.filter { $0.name.lowercased().contains("camera") }.count) readings") { [weak self] in self?.showMetrics("Cameras", kind: "cameras") },
            button("Models & planning", icon: "cpu") { [weak self] in self?.showMetrics("Models & planning", kind: "models") },
            button("Driving", icon: "car.side") { [weak self] in self?.showMetrics("Driving", kind: "driving") },
            button("Display", icon: "display", value: rate("UI")) { [weak self] in self?.showMetrics("Display", kind: "display") },
            button("External GPU", icon: "cpu") { [weak self] in self?.showMetrics("External GPU", kind: "external") },
            button("Other rates", icon: "waveform.path") { [weak self] in self?.showMetrics("Other rates", kind: "other") }
        ])
        if let page = controller?.topTemplate as? CPGridTemplate, page.userInfo is MetricPageState { updateMetrics(page) }
    }

    private func rateGroup(_ metric: DiagnosticMetric) -> String {
        let name = metric.name.lowercased()
        if external(metric) { return "external" }
        if name.contains("camera") { return "cameras" }
        if name.contains("model") || name.contains("plan") { return "models" }
        if name.contains("carstate") || name.contains("carcontrol") || name.contains("selfdrive") { return "driving" }
        if name == "ui" { return "display" }
        return "other"
    }

    private func showMetrics(_ title: String, kind: String) {
        guard let controller else { return }
        let page = CPGridTemplate(title: title, gridButtons: [])
        page.userInfo = MetricPageState(title: title, kind: kind)
        updateMetrics(page)
        controller.pushTemplate(page, animated: true, completion: nil)
    }

    private func updateMetrics(_ page: CPGridTemplate) {
        guard let state = page.userInfo as? MetricPageState else { return }
        let diagnostics = AppModel.shared.diagnostics
        guard diagnostics.fresh, let sample = diagnostics.snapshot else {
            page.updateGridButtons([button("Telemetry unavailable", icon: "exclamationmark.triangle") { [weak self] in self?.notice(diagnostics.status) }])
            return
        }
        let readings = sample.temperatures.filter { thermalGroup($0) == state.kind } + sample.rates.filter { rateGroup($0) == state.kind }
        let count = max(1, (readings.count + 5) / 6)
        state.index = min(state.index, count - 1)
        var buttons = readings.dropFirst(state.index * 6).prefix(6).map { button($0.name, icon: "gauge", value: $0.display) }
        if buttons.isEmpty { buttons = [button("No readings available", icon: "questionmark.circle")] }
        if state.index > 0 { buttons.append(button("Previous", icon: "arrow.left") { [weak self, weak page] in
            guard let self, let page else { return }; state.index -= 1; self.updateMetrics(page)
        }) }
        if state.index + 1 < count { buttons.append(button("More", icon: "arrow.right") { [weak self, weak page] in
            guard let self, let page else { return }; state.index += 1; self.updateMetrics(page)
        }) }
        page.updateTitle(count > 1 ? "\(state.title) · \(state.index + 1)/\(count)" : state.title)
        page.updateGridButtons(buttons)
    }

    private var session: String {
        let model = AppModel.shared
        return model.transport.usesLAN ? "lan-" + model.lan.generation : "ble-" + model.bluetooth.sessionIdentifier
    }

    private func request(_ path: String, method: String = "GET", body: Data = Data()) async throws -> Any {
        guard AppModel.shared.transport.connected else { throw BridgeError.message("Connect your iPhone to comma first.") }
        let original = session
        let response = try await AppModel.shared.transport.request(path: path, method: method,
            headers: body.isEmpty ? [:] : ["Content-Type": "application/json"], body: body)
        try Task.checkCancellation()
        guard original == session, AppModel.shared.transport.connected else { throw BridgeError.message("Connection changed. Please try again.") }
        guard response.status == 200 else { throw BridgeError.message("Galaxy request failed (HTTP \(response.status)). Use Galaxy on iPhone for details.") }
        return try JSONSerialization.jsonObject(with: response.bodyData)
    }

    private func loadGalaxy() {
        guard !busy else { return }
        busy = true
        toggles?.updateGridButtons([button("Loading Galaxy…", icon: "hourglass")])
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let original = self.session
                let layout = try await self.request("/assets/components/tools/device_settings_layout.json") as? [[String: Any]] ?? []
                let values = try await self.request("/api/params/all") as? [String: Any] ?? [:]
                guard original == self.session else { throw BridgeError.message("Connection changed. Try again.") }
                self.catalogue = layout; self.values = values
                self.showCategories()
            } catch {
                guard !Task.isCancelled else { return }
                self.toggles?.updateGridButtons([self.button("Retry Galaxy menus", icon: "arrow.clockwise") { [weak self] in self?.loadGalaxy() }])
                self.notice(error.localizedDescription)
            }
        }
    }

    private func showCategories() {
        guard let toggles else { return }
        let count = max(1, (catalogue.count + 5) / 6)
        categoryPage = min(categoryPage, count - 1)
        var buttons = catalogue.dropFirst(categoryPage * 6).prefix(6).map { section in
            let name = section["name"] as? String ?? "Settings"
            return button(name, icon: "switch.2") { [weak self] in self?.showSettings(section) }
        }
        if categoryPage > 0 { buttons.append(button("Previous menus", icon: "arrow.left") { [weak self] in self?.categoryPage -= 1; self?.showCategories() }) }
        if categoryPage + 1 < count { buttons.append(button("More menus", icon: "arrow.right") { [weak self] in self?.categoryPage += 1; self?.showCategories() }) }
        toggles.updateTitle(count > 1 ? "Galaxy toggles · \(categoryPage + 1)/\(count)" : "Galaxy toggles")
        toggles.updateGridButtons(buttons)
    }

    private func bool(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private func visible(_ param: [String: Any]) -> Bool {
        if param["settings_tier"] as? String != "simple", bool(values["GalaxyDeveloperMode"]) != true { return false }
        if let required = param["requires_capability"] as? String, bool(values[required]) != true { return false }
        if let required = param["visible_when_all_true"] as? [String], required.contains(where: { bool(values[$0]) != true }) { return false }
        if let makes = param["vehicle_makes"] as? [String], !makes.contains(values["CarMake"] as? String ?? "") { return false }
        return true
    }

    private func showSettings(_ section: [String: Any]) {
        let name = section["name"] as? String ?? "Galaxy"
        let params = (section["params"] as? [[String: Any]] ?? []).filter(visible)
        let page = CPGridTemplate(title: name, gridButtons: [])
        settingsPage(page, title: name, params: params, index: 0)
        controller?.pushTemplate(page, animated: true, completion: nil)
    }

    private func settingsPage(_ page: CPGridTemplate, title: String, params: [[String: Any]], index: Int) {
        let count = max(1, (params.count + 5) / 6)
        let current = min(index, count - 1)
        var buttons = params.dropFirst(current * 6).prefix(6).map { param in
            let key = param["key"] as? String ?? ""
            let label = param["label"] as? String ?? key
            let value = bool(values[key]).map { $0 ? "On" : "Off" } ?? "iPhone"
            return button(label, icon: "switch.2", value: value) { [weak self, weak page] in
                self?.confirmToggle(param, page: page, title: title, params: params, index: current)
            }
        }
        if buttons.isEmpty { buttons = [button("Use Galaxy on iPhone", icon: "iphone")] }
        if current > 0 { buttons.append(button("Previous", icon: "arrow.left") { [weak self, weak page] in
            if let page { self?.settingsPage(page, title: title, params: params, index: current - 1) }
        }) }
        if current + 1 < count { buttons.append(button("More", icon: "arrow.right") { [weak self, weak page] in
            if let page { self?.settingsPage(page, title: title, params: params, index: current + 1) }
        }) }
        page.updateTitle(count > 1 ? "\(title) · \(current + 1)/\(count)" : title)
        page.updateGridButtons(buttons)
    }

    private func confirmToggle(_ param: [String: Any], page: CPGridTemplate?, title: String, params: [[String: Any]], index: Int) {
        guard !busy, let key = param["key"] as? String, param["ui_type"] as? String == "toggle",
              param["data_type"] as? String == "bool", let current = bool(values[key]),
              param["confirm_message"] == nil, param["requires_capability"] == nil,
              !["ExperimentalMode", "ConditionalExperimental", "ConditionalChill", "ForceOffroad"].contains(key) else {
            notice("This control needs its full editor. Open Galaxy on your iPhone."); return
        }
        let original = session
        let label = param["label"] as? String ?? key
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.controller?.dismissTemplate(animated: true, completion: nil) }
        let apply = CPAlertAction(title: current ? "Turn off" : "Turn on", style: .default) { [weak self, weak page] _ in
            guard let self else { return }
            self.controller?.dismissTemplate(animated: true, completion: nil)
            self.busy = true
            self.work = Task { [weak self, weak page] in
                guard let self else { return }
                defer { self.busy = false }
                do {
                    guard original == self.session else { throw BridgeError.message("Connection changed. Please try again.") }
                    let fresh = try await self.request("/api/params/all") as? [String: Any] ?? [:]
                    let device = try await self.request("/api/device/status") as? [String: Any] ?? [:]
                    guard original == self.session, self.bool(fresh["IsOnroad"]) == false,
                          device["status"] as? String == "Parked",
                          self.bool(fresh["VehicleParked"]) == true,
                          self.bool(fresh[key]) == current else {
                        throw BridgeError.message("Park first, then refresh Galaxy toggles before changing a setting.")
                    }
                    self.values = fresh
                    guard self.visible(param) else { throw BridgeError.message("This setting is no longer available. Refresh Galaxy.") }
                    if param["requires_parked"] as? Bool == true, self.bool(fresh["VehicleParked"]) != true {
                        throw BridgeError.message("Put the vehicle in Park first.")
                    }
                    if let parent = param["parent_key"] as? String, self.bool(fresh[parent]) != true {
                        throw BridgeError.message("Enable the parent setting in Galaxy first.")
                    }
                    if let required = param["requires_nonempty_key"] as? String, String(describing: fresh[required] ?? "").isEmpty {
                        throw BridgeError.message("Finish configuring this setting in Galaxy on iPhone.")
                    }
                    let payload = try JSONSerialization.data(withJSONObject: ["key": key, "value": !current, "label": label])
                    guard original == self.session else { throw BridgeError.message("Connection changed. Please try again.") }
                    _ = try await self.request("/api/params", method: "PUT", body: payload)
                    self.values = try await self.request("/api/params/all") as? [String: Any] ?? [:]
                    if let page { self.settingsPage(page, title: title, params: params, index: index) }
                } catch {
                    if !Task.isCancelled { self.notice(error.localizedDescription) }
                }
            }
        }
        controller?.presentTemplate(CPAlertTemplate(titleVariants: ["\(label): \(current ? "On" : "Off") → \(current ? "Off" : "On")\nChanges are available while parked."], actions: [cancel, apply]), animated: true, completion: nil)
    }

    private func notice(_ message: String) {
        guard controller?.presentedTemplate == nil else { return }
        let action = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.controller?.dismissTemplate(animated: true, completion: nil) }
        controller?.presentTemplate(CPAlertTemplate(titleVariants: [String(message.prefix(240))], actions: [action]), animated: true, completion: nil)
    }
}
