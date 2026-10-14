import CarPlay
import UIKit
import CoreFoundation

@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPTabBarTemplateDelegate, CPSessionConfigurationDelegate {
    private final class GridAction: NSObject {
        var perform: @MainActor () -> Void
        var signature: String
        init(signature: String, perform: @escaping @MainActor () -> Void) {
            self.signature = signature; self.perform = perform
        }
    }
    private let gridActions = NSMapTable<CPGridButton, GridAction>.weakToStrongObjects()
    private final class WeakGrid {
        weak var page: CPGridTemplate?
        init(_ page: CPGridTemplate) { self.page = page }
    }
    private var sessionConfiguration: CPSessionConfiguration?
    private var controller: CPInterfaceController?
    private var timer: Timer?
    private var work: Task<Void, Never>?
    private var overview: CPGridTemplate?
    private var temperatures: CPGridTemplate?
    private var rates: CPGridTemplate?
    private var toggles: CPGridTemplate?
    private var catalogue: [[String: Any]] = []
    private var values: [String: Any] = [:]
    private var valuesSession = ""
    private var valuesAt = Date.distantPast
    private var categoryPage = 0
    private var busy = false
    private var navigating = false
    private final class GridRefresh: NSObject {
        let perform: @MainActor () -> Void
        init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    }
    private let settingsRefresh = NSMapTable<CPGridTemplate, GridRefresh>.weakToStrongObjects()
    private let overflowParents = NSMapTable<CPTemplate, CPTemplate>.weakToStrongObjects()
    private let gridSizes = NSMapTable<CPGridTemplate, NSNumber>.weakToStrongObjects()
    private final class MetricPageState {
        let title: String
        let kind: String
        var index = 0
        init(title: String, kind: String) { self.title = title; self.kind = kind }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        overview = nil; temperatures = nil; rates = nil; toggles = nil
        let model = AppModel.shared
        model.setCarPlayActive(true)
        refreshTelemetry()
        catalogue = localCatalogue()
        toggles = grid("Toggles", icon: "switch.2", buttons: categoryButtons())
        guard let overview, let temperatures, let rates, let toggles else { return }
        let tabs = CPTabBarTemplate(templates: [overview, temperatures, rates, toggles])
        tabs.delegate = self
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
        showCategories()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTelemetry() }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        timer?.invalidate(); timer = nil
        work?.cancel(); work = nil
        controller = nil
        sessionConfiguration?.delegate = nil; sessionConfiguration = nil
        overview = nil; temperatures = nil; rates = nil; toggles = nil
        catalogue = []; values = [:]; busy = false; categoryPage = 0; valuesSession = ""; valuesAt = .distantPast
        gridActions.removeAllObjects(); gridSizes.removeAllObjects(); overflowParents.removeAllObjects(); settingsRefresh.removeAllObjects(); navigating = false
        AppModel.shared.setCarPlayActive(false)
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if selectedTemplate === toggles { loadGalaxy() }
    }

    private var carAppearance: UIUserInterfaceStyle {
        if let style = sessionConfiguration?.contentStyle {
            if style.contains(.dark) && !style.contains(.light) { return .dark }
            if style.contains(.light) && !style.contains(.dark) { return .light }
        }
        return controller?.carTraitCollection.userInterfaceStyle == .dark ? .dark : .light
    }

    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration, contentStyleChanged contentStyle: CPContentStyle) {
        let appearance: UIUserInterfaceStyle = contentStyle.contains(.dark) && !contentStyle.contains(.light) ? .dark :
            contentStyle.contains(.light) && !contentStyle.contains(.dark) ? .light : carAppearance
        let traits = UITraitCollection(userInterfaceStyle: appearance)
        let templates = controller?.templates ?? []
        var visited = Set<ObjectIdentifier>()
        for template in templates.flatMap({ ($0 as? CPTabBarTemplate)?.templates ?? [$0] }) {
            guard let grid = template as? CPGridTemplate, visited.insert(ObjectIdentifier(grid)).inserted else { continue }
            for button in grid.gridButtons {
                if #available(iOS 26.0, *), let asset = button.image.imageAsset { button.updateImage(asset.image(with: traits)) }
            }
        }
    }

    private func pushTemplate(_ template: CPTemplate, animated: Bool, completion: ((Bool, Error?) -> Void)?) {
        guard let controller, !navigating else { completion?(false, nil); return }
        navigating = true
        let finished: (Bool, Error?) -> Void = { [weak self, weak controller] success, error in
            guard let self, let controller, self.controller === controller else { return }
            self.navigating = false
            completion?(success, error)
            if !success { self.notice(error?.localizedDescription ?? "This page could not be opened.") }
        }
        // A tab container also occupies a hierarchy level. Reserve that level before pushing.
        if controller.templates.count >= 4, let parent = controller.topTemplate {
            controller.popTemplate(animated: false) { [weak self, weak controller] success, error in
                guard let self, let controller, self.controller === controller else { return }
                guard success else { finished(false, error); return }
                self.overflowParents.setObject(parent, forKey: template)
                if let page = template as? CPBarButtonProviding {
                    page.backButton = CPBarButton(image: UIImage(systemName: "chevron.left")!) { [weak self] _ in
                        self?.popTemplate(animated: true, completion: nil)
                    }
                }
                controller.pushTemplate(template, animated: animated, completion: finished)
            }
        } else {
            controller.pushTemplate(template, animated: animated, completion: finished)
        }
    }

    private func popTemplate(animated: Bool, completion: ((Bool, Error?) -> Void)?) {
        guard let controller, !navigating else { completion?(false, nil); return }
        let top = controller.topTemplate
        let parent = top.flatMap { overflowParents.object(forKey: $0) }
        navigating = true
        controller.popTemplate(animated: animated) { [weak self, weak controller] success, error in
            guard let self, let controller, self.controller === controller else { return }
            guard success else { self.navigating = false; completion?(false, error); return }
            if let top { self.overflowParents.removeObject(forKey: top) }
            if let parent {
                controller.pushTemplate(parent, animated: false) { [weak self] restored, error in
                    self?.navigating = false; completion?(restored, error)
                }
            } else {
                self.navigating = false; completion?(true, nil)
            }
        }
    }

    private func paddedButtons(_ buttons: [CPGridButton], capacity: Int = 8) -> [CPGridButton] {
        var result = Array(buttons.prefix(capacity))
        while result.count < capacity {
            let empty = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
            let action = GridAction(signature: "empty", perform: {})
            let spacer = CPGridButton(titleVariants: [" "], image: empty) { _ in action.perform() }
            gridActions.setObject(action, forKey: spacer)
            spacer.isEnabled = false
            result.append(spacer)
        }
        return result
    }

    private func makeGrid(title: String?, gridButtons: [CPGridButton], compact: Bool = false) -> CPGridTemplate {
        let capacity = compact ? 4 : 8
        let page = CPGridTemplate(title: title, gridButtons: paddedButtons(gridButtons, capacity: capacity))
        gridSizes.setObject(NSNumber(value: capacity), forKey: page)
        return page
    }

    private func grid(_ title: String, icon: String, buttons: [CPGridButton]) -> CPGridTemplate {
        precondition(!buttons.isEmpty)
        let template = makeGrid(title: title, gridButtons: buttons)
        template.tabTitle = title
        template.tabImage = UIImage(systemName: icon)
        return template
    }

    private func button(_ title: String, icon: String, value: String? = nil, action: @escaping @MainActor () -> Void = {}) -> CPGridButton {
        let configuration = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        let symbol = UIImage(systemName: icon, withConfiguration: configuration) ?? UIImage(systemName: "circle")!
        let image: UIImage
        if let value {
            let format = UIGraphicsImageRendererFormat()
            format.scale = controller?.carTraitCollection.displayScale ?? 2
            let text = value.replacingOccurrences(of: " °C", with: "°").replacingOccurrences(of: " FPS", with: "")
            let asset = UIImageAsset()
            for (style, color) in [(UIUserInterfaceStyle.light, UIColor.black), (.dark, UIColor.white)] {
                let rendered = UIGraphicsImageRenderer(size: CGSize(width: 72, height: 72), format: format).image { _ in
                    if value == "On" || value == "Off" {
                        let on = value == "On"
                        (on ? UIColor.systemGreen : (style == .dark ? UIColor.darkGray : UIColor.systemGray)).setFill()
                        UIBezierPath(roundedRect: CGRect(x: 3, y: 7, width: 66, height: 36), cornerRadius: 18).fill()
                        UIColor.white.setFill()
                        UIBezierPath(ovalIn: CGRect(x: on ? 36 : 6, y: 10, width: 30, height: 30)).fill()
                    } else {
                        symbol.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 22, y: 0, width: 28, height: 28))
                    }
                    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
                    let size: CGFloat = text.count <= 6 ? 24 : text.count <= 10 ? 18 : 14
                    (text as NSString).draw(in: CGRect(x: 0, y: value == "On" || value == "Off" ? 47 : 36, width: 72, height: 25), withAttributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
                        .foregroundColor: color, .paragraphStyle: paragraph
                    ])
                }.withRenderingMode(.alwaysOriginal)
                asset.register(rendered, with: UITraitCollection(traitsFrom: [
                    UITraitCollection(userInterfaceStyle: style), UITraitCollection(displayScale: format.scale)
                ]))
            }
            image = asset.image(with: UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: carAppearance), UITraitCollection(displayScale: format.scale)
            ]))
        } else { image = symbol.withRenderingMode(.alwaysTemplate) }
        let label = title
        let state = GridAction(signature: "\(title)|\(icon)|\(value ?? "")", perform: action)
        let result = CPGridButton(titleVariants: [label, compactCaption(label)], image: image) { _ in state.perform() }
        gridActions.setObject(state, forKey: result)
        return result
    }

    private func compactCaption(_ label: String) -> String {
        label.replacingOccurrences(of: "Advanced ", with: "Adv. ")
            .replacingOccurrences(of: "Longitudinal", with: "Speed")
            .replacingOccurrences(of: "Lateral", with: "Steering")
            .replacingOccurrences(of: "Acceleration", with: "Accel.")
            .replacingOccurrences(of: "Deceleration", with: "Braking")
            .replacingOccurrences(of: "Conditional ", with: "")
            .replacingOccurrences(of: "Controller", with: "Control")
    }

    private func updateGrid(_ page: CPGridTemplate, buttons rawButtons: [CPGridButton]) {
        precondition(!rawButtons.isEmpty)
        let buttons = paddedButtons(rawButtons, capacity: gridSizes.object(forKey: page)?.intValue ?? 8)
        if #available(iOS 26.0, *), page.gridButtons.count == buttons.count {
            for (existing, replacement) in zip(page.gridButtons, buttons) {
                guard let current = gridActions.object(forKey: existing),
                      let next = gridActions.object(forKey: replacement) else {
                    page.updateGridButtons(buttons)
                    return
                }
                current.perform = next.perform
                existing.isEnabled = replacement.isEnabled
                if current.signature != next.signature {
                    existing.updateTitleVariants(replacement.titleVariants)
                    existing.updateImage(replacement.image)
                    current.signature = next.signature
                }
            }
        } else {
            page.updateGridButtons(buttons)
        }
    }

    private func telemetryGrid(_ existing: CPGridTemplate?, title: String, icon: String,
                               buttons: [CPGridButton]) -> CPGridTemplate {
        if let existing { updateGrid(existing, buttons: buttons); return existing }
        return grid(title, icon: icon, buttons: buttons)
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

    private func thermalLabel(_ group: String) -> String {
        switch group {
        case "Processors": return "CPU / DSP"
        case "Onboard GPU": return "GPU"
        case "Connectivity": return "Radios"
        case "Other sensors": return "Sensors"
        default: return group
        }
    }

    private func thermalIcon(_ group: String) -> String {
        switch group {
        case "Processors", "Onboard GPU", "External GPU": return "cpu"
        case "Memory": return "memorychip"
        case "Cooling": return "fan"
        case "Power": return "bolt"
        case "Connectivity": return "antenna.radiowaves.left.and.right"
        default: return "thermometer.medium"
        }
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
        overview = telemetryGrid(overview, title: "Overview", icon: "car.side", buttons: [
            button(model.transport.connected ? model.transport.label : "Offline", icon: "antenna.radiowaves.left.and.right") { [weak self] in
                self?.notice(diagnostics.fresh ? "Telemetry connected." : diagnostics.status)
            },
            button("Status", icon: "car.side", value: sample?.engaged.map { $0 ? "Engaged" : "Inactive" } ?? "—"),
            button("CPU / DSP", icon: "cpu", value: maximum(temps.filter { thermalGroup($0) == "Processors" })),
            button("GPU", icon: "cpu", value: maximum(temps.filter { thermalGroup($0) == "Onboard GPU" })),
            button("Memory", icon: "memorychip", value: maximum(temps.filter { thermalGroup($0) == "Memory" })),
            button("Display", icon: "display", value: rate("UI")),
            button("Model", icon: "speedometer", value: rate("modelV2")),
            button("External GPU", icon: "cpu", value: maximum(temps.filter(external)))
        ])
        let groups = ["Processors", "Onboard GPU", "Memory", "Cooling", "Power", "Connectivity", "External GPU", "Other sensors"]
        temperatures = telemetryGrid(temperatures, title: "Temps", icon: "thermometer.medium", buttons: groups.map { group in
            button(thermalLabel(group), icon: thermalIcon(group), value: maximum(temps.filter { thermalGroup($0) == group })) { [weak self] in
                self?.showMetrics(group, kind: group)
            }
        })
        rates = telemetryGrid(rates, title: "Rates", icon: "speedometer", buttons: [
            button("Cameras", icon: "camera") { [weak self] in self?.showMetrics("Cameras", kind: "cameras") },
            button("Models", icon: "cpu") { [weak self] in self?.showMetrics("Models & planning", kind: "models") },
            button("Driving", icon: "car.side") { [weak self] in self?.showMetrics("Driving", kind: "driving") },
            button("Display", icon: "display", value: rate("UI")) { [weak self] in self?.showMetrics("Display", kind: "display") },
            button("External GPU", icon: "cpu") { [weak self] in self?.showMetrics("External GPU", kind: "external") },
            button("Other", icon: "waveform.path") { [weak self] in self?.showMetrics("Other rates", kind: "other") }
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
        guard controller != nil else { return }
        let page = makeGrid(title: title, gridButtons: [button("Loading readings…", icon: "hourglass")])
        page.userInfo = MetricPageState(title: title, kind: kind)
        updateMetrics(page)
        pushTemplate(page, animated: true, completion: nil)
    }

    private func updateMetrics(_ page: CPGridTemplate) {
        guard let state = page.userInfo as? MetricPageState else { return }
        let diagnostics = AppModel.shared.diagnostics
        guard diagnostics.fresh, let sample = diagnostics.snapshot else {
            updateGrid(page, buttons: [button("Telemetry unavailable", icon: "exclamationmark.triangle") { [weak self] in self?.notice(diagnostics.status) }])
            return
        }
        let readings = sample.temperatures.filter { thermalGroup($0) == state.kind } + sample.rates.filter { rateGroup($0) == state.kind }
        let count = max(1, (readings.count + 7) / 8)
        state.index = min(state.index, count - 1)
        var buttons = readings.dropFirst(state.index * 8).prefix(8).map { button($0.name, icon: "gauge", value: $0.display) }
        if buttons.isEmpty { buttons = [button("No readings available", icon: "questionmark.circle")] }
        paging(page, index: state.index, count: count) { [weak self, weak page] index in
            guard let self, let page else { return }; state.index = index; self.updateMetrics(page)
        }
        page.updateTitle(count > 1 ? "\(state.title) · \(state.index + 1)/\(count)" : state.title)
        updateGrid(page, buttons: buttons)
    }

    private var session: String {
        let model = AppModel.shared
        return model.transport.usesLAN ? "lan-" + model.lan.generation : "ble-" + model.bluetooth.sessionIdentifier
    }

    private func request(_ path: String, method: String = "GET", body: Data = Data()) async throws -> Any {
        guard AppModel.shared.transport.connected else { throw BridgeError.message("Connect your iPhone to comma first.") }
        let original = session
        let started = Date()
        defer {
            if path == "/api/params/all?galaxy_ble_settings=1" || path.hasPrefix("/assets/") {
                AppModel.shared.connectionLog.record("CarPlay read \(path): \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            }
        }
        let response = try await AppModel.shared.transport.request(path: path, method: method,
            headers: body.isEmpty ? [:] : ["Content-Type": "application/json"], body: body)
        try Task.checkCancellation()
        guard original == session, AppModel.shared.transport.connected else { throw BridgeError.message("Connection changed. Please try again.") }
        guard response.status == 200 else { throw BridgeError.message("Galaxy request failed (HTTP \(response.status)). Use Galaxy on iPhone for details.") }
        return try JSONSerialization.jsonObject(with: response.bodyData)
    }

    private func localCatalogue() -> [[String: Any]] {
        let assets = AppModel.shared.assets
        let root = assets.inUseRoot ?? assets.readyRoot ?? assets.bundledRoot
        let path = root.appendingPathComponent("assets/components/tools/device_settings_layout.json")
        guard let data = try? Data(contentsOf: path),
              data.count <= 1_048_576,
              let sections = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return prepareCatalogue(sections)
    }

    private func prepareCatalogue(_ sections: [[String: Any]]) -> [[String: Any]] {
        var result = sections.map { section in
            var section = section
            let original = section["params"] as? [[String: Any]] ?? []
            let byKey = Dictionary(original.compactMap { p -> (String, [String: Any])? in
                guard let key = p["key"] as? String else { return nil }; return (key, p)
            }, uniquingKeysWith: { first, _ in first })
            section["params"] = original.compactMap { p -> [String: Any]? in
                let key = p["key"] as? String ?? ""
                if ["ExperimentalMode", "ConditionalChill"].contains(key) { return nil }
                if key == "ConditionalExperimental" {
                    return ["key": "LongitudinalControlMode", "label": "Longitudinal control mode",
                            "ui_type": "dropdown", "data_type": "string", "settings_tier": "simple",
                            "description": "Chill uses conventional speed control. Experimental uses model-controlled gas and brakes. Conditional modes switch under your configured conditions.",
                            "options": [
                                ["value": "chill", "label": "Chill"], ["value": "experimental", "label": "Experimental"],
                                ["value": "conditional_experimental", "label": "Conditional Experimental"],
                                ["value": "conditional_chill", "label": "Conditional Chill"]
                            ]]
                }
                var updated = p, parent = p["parent_key"] as? String
                if let kind = p["galaxy_ui_type"] { updated["ui_type"] = kind }
                var seen = Set<String>()
                while let ancestor = parent, seen.insert(ancestor).inserted {
                    if ["ConditionalExperimental", "ConditionalChill"].contains(ancestor) {
                        updated["longitudinal_mode"] = ancestor == "ConditionalExperimental" ? "conditional_experimental" : "conditional_chill"
                        updated["settings_tier"] = "simple"
                        if p["parent_key"] as? String == ancestor { updated["parent_key"] = "LongitudinalControlMode" }
                        break
                    }
                    parent = byKey[ancestor]?["parent_key"] as? String
                }
                return updated
            }
            return section
        }
        if !result.contains(where: { $0["name"] as? String == "Language" }) {
            result.append(["name": "Language", "params": [["key": "LanguageSetting", "label": "Language", "ui_type": "language", "settings_tier": "simple"]]])
        }
        return result
    }

    private func mergeValues(_ fresh: [String: Any]) {
        values = fresh
        values["LongitudinalControlMode"] = bool(fresh["ConditionalExperimental"]) == true ? "conditional_experimental" :
            bool(fresh["ConditionalChill"]) == true ? "conditional_chill" :
            bool(fresh["ExperimentalMode"]) == true ? "experimental" : "chill"
    }

    private func loadGalaxy() {
        if !catalogue.isEmpty { showCategories(); return }
        guard !busy else { return }
        busy = true
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let layout = try await self.request("/assets/components/tools/device_settings_layout.json") as? [[String: Any]] ?? []
                guard !layout.isEmpty else { throw BridgeError.message("Galaxy menus are unavailable. Try again when connected.") }
                self.catalogue = self.prepareCatalogue(layout)
                self.showCategories()
            } catch {
                guard !Task.isCancelled else { return }
                self.notice(error.localizedDescription)
            }
        }
    }

    private func categoryLabel(_ name: String) -> String {
        if name.hasPrefix("Lateral") { return "Steering" }
        if name.hasPrefix("Longitudinal") { return "Speed & following" }
        if name.hasPrefix("Visual") { return "Display" }
        if name.hasPrefix("Vision") { return "Speed limits" }
        return name
    }

    private func categoryIcon(_ name: String) -> String {
        if name.hasPrefix("Favorites") { return "star" }
        if name.hasPrefix("Lateral") || name.hasPrefix("Wheel") { return "steeringwheel" }
        if name.hasPrefix("Longitudinal") { return "speedometer" }
        if name.hasPrefix("Vision") { return "signpost.right" }
        if name.hasPrefix("Visual") { return "display" }
        if name.hasPrefix("Sounds") { return "speaker.wave.2" }
        if name.hasPrefix("Vehicle") { return "car.side" }
        if name.hasPrefix("Device") { return "internaldrive" }
        if name.hasPrefix("Developer") { return "hammer" }
        if name == "Language" { return "globe" }
        return "switch.2"
    }

    private func categoryButtons() -> [CPGridButton] {
        guard !catalogue.isEmpty else {
            return [button("Load menus", icon: "arrow.clockwise") { [weak self] in self?.loadGalaxy() }]
        }
        var buttons = catalogue.prefix(catalogue.count > 8 ? 7 : 8).map { section in
            let name = section["name"] as? String ?? "Settings"
            return button(categoryLabel(name), icon: categoryIcon(name)) { [weak self] in self?.openSettings(section) }
        }
        if catalogue.count > 8 {
            buttons.append(button("All menus", icon: "square.grid.2x2") { [weak self] in self?.allCategories() })
        }
        return buttons
    }

    private func allCategories() {
        let page = makeGrid(title: "Toggle menus", gridButtons: categoryButtons())
        let reference = WeakGrid(page)
        @MainActor func render(_ index: Int) {
            guard let page = reference.page else { return }
            let count = max(1, (catalogue.count + 7) / 8), current = min(index, count - 1)
            categoryPage = current
            let buttons = catalogue.dropFirst(current * 8).prefix(8).map { section in
                let name = section["name"] as? String ?? "Settings"
                return button(categoryLabel(name), icon: categoryIcon(name)) { [weak self] in
                    self?.popTemplate(animated: false, completion: { [weak self] success, _ in
                        if success { self?.openSettings(section) }
                    })
                }
            }
            updateGrid(page, buttons: buttons)
            page.updateTitle("Toggle menus · \(current + 1)/\(count)")
            paging(page, index: current, count: count, change: render)
        }
        render(categoryPage); pushTemplate(page, animated: true, completion: nil)
    }

    private func showCategories() {
        guard let toggles else { return }
        updateGrid(toggles, buttons: categoryButtons())
        toggles.trailingNavigationBarButtons = []
    }

    private func openSettings(_ section: [String: Any]) {
        guard !busy else { return }
        if valuesSession == session, Date().timeIntervalSince(valuesAt) < 30 {
            showSettings(section); return
        }
        let name = categoryLabel(section["name"] as? String ?? "Settings")
        let loading = makeGrid(title: name, gridButtons: [
            button("Reading settings…", icon: "arrow.triangle.2.circlepath")
        ])
        pushTemplate(loading, animated: true, completion: nil)
        busy = true
        work = Task { [weak self, weak loading] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let original = self.session
                let fresh = try await self.request("/api/params/all?galaxy_ble_settings=1") as? [String: Any] ?? [:]
                guard original == self.session else { throw BridgeError.message("Connection changed. Try again.") }
                self.mergeValues(fresh); self.valuesSession = original; self.valuesAt = Date()
                guard let loading, self.controller?.topTemplate === loading else { return }
                let params = (section["params"] as? [[String: Any]] ?? []).filter(self.visible)
                self.settingsPage(loading, title: name, params: params, index: 0)
            } catch {
                guard !Task.isCancelled, let loading, self.controller?.topTemplate === loading else { return }
                self.updateGrid(loading, buttons: [
                    self.button("Retry", icon: "arrow.clockwise") { [weak self] in
                        self?.popTemplate(animated: false, completion: nil)
                        self?.openSettings(section)
                    }
                ])
                self.notice(error.localizedDescription)
            }
        }
    }

    private func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let n = value as? NSNumber { return n.boolValue }
        switch String(describing: value).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "", "no", "off": return false
        default: return nil
        }
    }

    private func visible(_ param: [String: Any]) -> Bool {
        let key = param["key"] as? String ?? ""
        let makesByKey: [String: [String]] = [
            "RivianAngleControl": ["Rivian"],
            "TeslaCoopSteering": ["Tesla"],
            "NAPRadarEnabled": ["Tesla"],
            "NAPRadarBehindNosecone": ["Tesla"],
            "NAPRadarOffset": ["Tesla"],
            "NAPPedalEnabled": ["Tesla"],
            "NAPPedalCanBus": ["Tesla"],
            "NAPAdaptiveAccel": ["Tesla"],
            "NAPPedalCalibDone": ["Tesla"],
            "NAPPedalCalibFactor": ["Tesla"],
            "NAPPedalCalibZero": ["Tesla"],
            "GMPedalLongitudinal": ["Buick", "Cadillac", "Chevrolet", "GMC", "Holden"],
            "GMDashSpoofOffsets": ["Buick", "Cadillac", "Chevrolet", "GMC", "Holden"],
            "IgnoreIgnitionLine": ["Buick", "Cadillac", "Chevrolet", "GMC", "Holden"],
            "LongPitch": ["Buick", "Cadillac", "Chevrolet", "GMC", "Holden"],
            "RemoteStartBootsComma": ["Buick", "Cadillac", "Chevrolet", "GMC", "Holden"],
            "HKGRemoteStartBootsComma": ["Genesis", "Hyundai", "Kia"],
            "VoltSNG": ["Chevrolet", "Holden"],
            "GMAutoHold": ["Buick", "Chevrolet", "Holden"],
            "VoltOnePedalMode": ["Chevrolet", "Holden"],
            "RemapCancelToDistance": ["Chevrolet", "Holden"],
            "JeepBrakeHold": ["Jeep"],
            "SubaruSNG": ["Subaru"],
            "SubaruSNGManualParkingBrake": ["Subaru"],
            "SubaruStopStartOff": ["Subaru"],
            "SubaruAvhStartup": ["Subaru"],
            "SubaruRedneckCruise": ["Subaru"],
            "SNGHack": ["Lexus", "Toyota"],
            "ToyotaAutoHold": ["Lexus", "Toyota"]
        ]
        let hidden: Set<String> = ["AccelerationProfile", "AggressiveFollow", "AggressiveFollowHigh", "CustomAccelProfile", "CustomAccelProfile0MPH", "CustomAccelProfile11MPH", "CustomAccelProfile22MPH", "CustomAccelProfile34MPH", "CustomAccelProfile45MPH", "CustomAccelProfile56MPH", "CustomAccelProfile89MPH", "DecelerationProfile", "EVTuning", "HumanAcceleration", "RelaxedFollow", "RelaxedFollowHigh", "StandardFollow", "StandardFollowHigh", "TrafficFollow", "TruckTuning"]
        if let mode = param["longitudinal_mode"] as? String, mode != values["LongitudinalControlMode"] as? String { return false }
        if hidden.contains(key) || key == "Model" { return false }
        if key != "StarPilotFavoriteSlots", param["settings_tier"] as? String != "simple", bool(values["GalaxyDeveloperMode"]) != true { return false }
        let make = String(describing: values["CarMake"] ?? "").lowercased()
        if let makes = (param["vehicle_makes"] as? [String]) ?? makesByKey[key], !makes.contains(where: { $0.lowercased() == make }) { return false }
        if let makes = param["excluded_vehicle_makes"] as? [String], makes.contains(where: { $0.lowercased() == make }) { return false }
        if let required = param["requires_capability"] as? String, bool(values[required]) != true { return false }
        if let required = param["visible_when_all_true"] as? [String], required.contains(where: { bool(values[$0]) != true }) { return false }
        if let dep = param["visible_when_key"] as? String, let allowed = param["visible_when_values"] as? [Any],
           !allowed.contains(where: { String(describing: $0) == String(describing: values[dep] ?? "") }) { return false }
        if ["HumanLaneChanges", "RadarTakeoffs"].contains(key), bool(values["HasRadar"]) != true { return false }
        if key == "AlphaLongitudinalEnabled", bool(values["AlphaLongitudinalAvailable"]) != true { return false }
        return true
    }

    private func paging(_ page: CPGridTemplate, index: Int, count: Int, change: @escaping @MainActor (Int) -> Void) {
        guard count > 1 else { page.trailingNavigationBarButtons = []; return }
        let previous = CPBarButton(image: UIImage(systemName: "chevron.left")!) { _ in change(index - 1) }
        let next = CPBarButton(image: UIImage(systemName: "chevron.right")!) { _ in change(index + 1) }
        previous.isEnabled = index > 0; next.isEnabled = index + 1 < count
        page.trailingNavigationBarButtons = [previous, next]
    }

    private func showSettings(_ section: [String: Any]) {
        let name = categoryLabel(section["name"] as? String ?? "Galaxy")
        let params = (section["params"] as? [[String: Any]] ?? []).filter(visible)
        let page = makeGrid(title: name, gridButtons: [button("Settings", icon: "gearshape")])
        settingsPage(page, title: name, params: params, index: 0)
        pushTemplate(page, animated: true, completion: nil)
    }

    private func number(_ value: Any?) -> Double? {
        guard let value else { return nil }
        let n = (value as? NSNumber)?.doubleValue ?? Double(String(describing: value))
        return n?.isFinite == true ? n : nil
    }

    private func parameter(_ original: [String: Any]) -> [String: Any] {
        var p = original
        if p["unit_type"] as? String == "vehicle_speed" {
            let prefix = bool(values["IsMetric"]) == true ? "metric_" : "imperial_"
            p["unit"] = prefix == "metric_" ? " km/h" : " mph"
            for field in ["min", "max", "step", "precision"] {
                if let override = p[prefix + field] { p[field] = override }
            }
        }
        return p
    }

    private func bounds(_ original: [String: Any]) -> (Double, Double, Double, Int) {
        let p = parameter(original), key = p["key"] as? String ?? ""
        var lo = number(p["min"]) ?? 0, hi = number(p["max"]) ?? 100
        var step = number(p["step"]) ?? (p["data_type"] as? String == "float" ? 0.01 : 1)
        if key == "LaneCenterOffset" { lo = -0.3; hi = 0.3; step = 0.01 }
        if key == "SteerKP" || key == "SteerLatAccel" || key == "SteerRatio" {
            let fallback = key == "SteerKP" ? 0.6 : key == "SteerLatAccel" ? 2.0 : 15.0
            let stock = number(values[key + "Stock"]) ?? 0, current = number(values[key]) ?? 0
            let base = stock != 0 ? stock : current != 0 ? current : fallback
            lo = base * (key == "SteerRatio" ? 0.25 : 0.5)
            hi = base * (key == "SteerLatAccel" ? 1.25 : 1.5)
            lo = (lo * 100).rounded() / 100; hi = (hi * 100).rounded() / 100; step = 0.01
        }
        if key.contains("Jerk") { lo = 25; hi = 200; step = 1 }
        let decimals = String(step).split(separator: ".").last?.count ?? 0
        return (lo, hi, max(0.0001, step), min(6, max(0, (p["precision"] as? Int) ?? (step == floor(step) ? 0 : decimals))))
    }

    private func valueLabel(_ p: [String: Any]) -> String {
        let key = p["key"] as? String ?? "", kind = p["ui_type"] as? String ?? ""
        if kind == "toggle" { return bool(values[key]).map { $0 ? "On" : "Off" } ?? "Unknown" }
        if let options = p["options"] as? [[String: Any]],
           let selected = options.first(where: { String(describing: $0["value"] ?? "") == String(describing: values[key] ?? "") }) {
            return selected["label"] as? String ?? ""
        }
        if kind == "numeric" || kind == "brightness" || kind == "readout", let n = number(values[key]) {
            if key.contains("Brightness"), n == 101 { return "Auto" }
            let resolved = parameter(p)
            return String(format: "%.*f", bounds(p).3, n) + (resolved["unit"] as? String ?? "")
        }
        return String(describing: values[key] ?? "Not reported")
    }

    private func settingCaption(_ p: [String: Any]) -> String {
        let names = [
            "LongitudinalControlMode": "Driving mode", "CurveSpeedController": "Curve speed",
            "CustomPersonalities": "Personalities", "LongitudinalTune": "Speed tuning",
            "QOLLongitudinal": "Driving comfort", "SpeedLimitController": "Speed limits",
            "AdvancedLongitudinalTune": "Advanced speed", "AdvancedLateralTune": "Advanced steering",
            "AlwaysOnLateral": "Always-on steering"
        ]
        let key = p["key"] as? String ?? ""
        return names[key] ?? (p["label"] as? String ?? key)
    }

    private func settingsPage(_ page: CPGridTemplate, title: String, params: [[String: Any]], index: Int, parent: String? = nil) {
        settingsRefresh.setObject(GridRefresh { [weak self, weak page] in
            if let page { self?.settingsPage(page, title: title, params: params, index: index, parent: parent) }
        }, forKey: page)
        let displayed = params.filter { (($0["parent_key"] as? String) == parent || (parent == nil && $0["_display_root"] as? Bool == true)) && visible($0) }
        let count = max(1, (displayed.count + 7) / 8), current = min(index, count - 1)
        var buttons = displayed.dropFirst(current * 8).prefix(8).map { p in
            let key = p["key"] as? String ?? "", label = p["label"] as? String ?? key
            let children = p["_enable_parent"] as? Bool != true && params.contains { $0["parent_key"] as? String == key && visible($0) }
            let kind = p["ui_type"] as? String ?? ""
            let icon = children || kind == "group" ? "folder" : kind == "numeric" ? "slider.horizontal.3" :
                kind == "dropdown" ? "list.bullet" : kind == "color" ? "paintpalette" :
                kind == "favorites" ? "star" : kind == "toggle" ? (bool(values[key]) == true ? "checkmark.circle.fill" : "circle") : "gearshape"
            return button(settingCaption(p), icon: icon, value: ["toggle", "numeric", "brightness", "dropdown", "color", "readout"].contains(kind) ? valueLabel(p) : nil) { [weak self] in
                guard let self else { return }
                if key == "LongitudinalControlMode", p["_enable_parent"] as? Bool != true { self.modeGroup(p, params: params) }
                else if key == "CustomPersonalities" { self.personalities() }
                else if children || kind == "group" {
                    self.showGroup(p, title: label, params: params)
                } else { self.edit(p) }
            }
        }
        if buttons.isEmpty { buttons = [button("No available settings", icon: "info.circle")] }
        paging(page, index: current, count: count) { [weak self, weak page] next in
            if let page { self?.settingsPage(page, title: title, params: params, index: next, parent: parent) }
        }
        page.updateTitle(count > 1 ? "\(title) · \(current + 1)/\(count)" : title)
        updateGrid(page, buttons: buttons)
    }

    private func showGroup(_ p: [String: Any], title: String, params: [[String: Any]]) {
        let key = p["key"] as? String ?? ""
        var children = params.filter { $0["parent_key"] as? String == key && visible($0) }
        if p["ui_type"] as? String == "toggle" {
            var enabled = p; enabled["label"] = "Enable"; enabled["parent_key"] = key; enabled.removeValue(forKey: "is_parent_toggle")
            enabled["_enable_parent"] = true
            children.insert(enabled, at: 0)
        }
        let page = makeGrid(title: title, gridButtons: [button("Settings", icon: "folder")])
        settingsPage(page, title: title, params: children + params.filter { $0["parent_key"] as? String != key }, index: 0, parent: key)
        pushTemplate(page, animated: true, completion: nil)
    }

    private func edit(_ p: [String: Any]) {
        let key = p["key"] as? String ?? "", label = p["label"] as? String ?? key
        let kind = p["ui_type"] as? String ?? ""
        switch kind {
        case "toggle":
            guard let old = bool(values[key]) else { notice("Read this setting again before editing."); return }
            apply(p, value: !old, expected: old)
        case "brightness": brightness(p)
        case "numeric":
            guard let old = number(values[key]) else { notice("No value reported for this setting."); return }
            numericEditor(p, original: old)
        case "dropdown":
            if key == "LongitudinalControlMode" { longitudinalMode(p) } else { dropdown(p) }
        case "language": language()
        case "color": colors(p)
        case "action": apply(p, value: NSNull(), expected: values[key] ?? NSNull())
        case "favorites": favorites()
        default: notice("\(label): \(valueLabel(p))\n\(p["description"] as? String ?? "")")
        }
    }

    private func numericEditor(_ p: [String: Any], original: Double) {
        let label = p["label"] as? String ?? "Value", limits = bounds(p)
        var draft = original
        let page = makeGrid(title: label, gridButtons: [button("Value", icon: "slider.horizontal.3")], compact: true)
        let reference = WeakGrid(page)
        @MainActor func redraw() {
            guard let page = reference.page else { return }
            let formatted = String(format: "%.*f", limits.3, draft) + (parameter(p)["unit"] as? String ?? "")
            updateGrid(page, buttons: [
                button("Decrease", icon: "minus.circle") { draft = max(limits.0, (round((draft - limits.0) / limits.2) - 1) * limits.2 + limits.0); redraw() },
                button(formatted, icon: "slider.horizontal.3") { [weak self] in self?.notice(p["description"] as? String ?? label) },
                button("Increase", icon: "plus.circle") { draft = min(limits.1, (round((draft - limits.0) / limits.2) + 1) * limits.2 + limits.0); redraw() },
                button("Save", icon: "checkmark") { [weak self] in self?.apply(p, value: p["data_type"] as? String == "int" ? Int(draft.rounded()) as Any : draft as Any, expected: original) }
            ])
        }
        redraw(); pushTemplate(page, animated: true, completion: nil)
    }

    private func choices(_ p: [String: Any], options: [[String: Any]], selected: (@MainActor (Any) -> Void)? = nil) {
        let title = p["label"] as? String ?? "Choose"
        let page = makeGrid(title: title, gridButtons: [button("Choose", icon: "list.bullet")], compact: options.count <= 4)
        let reference = WeakGrid(page)
        @MainActor func render(_ index: Int) {
            guard let page = reference.page else { return }
            let count = max(1, (options.count + 7) / 8), current = min(index, count - 1)
            var buttons = options.dropFirst(current * 8).prefix(8).map { choice in
                let v = choice["value"] ?? ""
                let isSelected = String(describing: values[p["key"] as? String ?? ""] ?? "") == String(describing: v)
                return button(choice["label"] as? String ?? String(describing: v), icon: isSelected ? "checkmark.circle.fill" : "circle") { [weak self] in
                    if let selected { selected(v) }
                    else { self?.apply(p, value: v, expected: self?.values[p["key"] as? String ?? ""] ?? NSNull()) }
                }
            }
            if buttons.isEmpty { buttons = [button("No choices reported", icon: "info.circle")] }
            paging(page, index: current, count: count, change: render)
            updateGrid(page, buttons: buttons)
        }
        render(0); pushTemplate(page, animated: true, completion: nil)
    }

    private func dropdown(_ p: [String: Any]) {
        if let options = p["options"] as? [[String: Any]] { choices(p, options: options); return }
        guard var endpoint = p["options_endpoint"] as? String, !busy else { notice("Choices unavailable."); return }
        for (key, value) in values {
            endpoint = endpoint.replacingOccurrences(of: "{\(key)}", with: String(describing: value).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=#?"))) ?? "")
        }
        guard endpoint.hasPrefix("/api/fingerprints/"), !endpoint.contains("{") else { notice("Select the car make first."); return }
        busy = true
        work = Task { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            do {
                let data = try await self.request(endpoint)
                let options = (data as? [[String: Any]]) ?? (data as? [String] ?? []).map { ["label": $0, "value": $0] }
                self.choices(p, options: options)
            } catch { if !Task.isCancelled { self.notice(error.localizedDescription) } }
        }
    }

    private func colors(_ p: [String: Any]) {
        choices(p, options: [
            ["label": "Stock", "value": "stock"], ["label": "White", "value": "#ffffff"],
            ["label": "Blue", "value": "#007aff"], ["label": "Green", "value": "#00ff00"],
            ["label": "Red", "value": "#ff3b30"], ["label": "Orange", "value": "#ff9500"],
            ["label": "Purple", "value": "#af52de"], ["label": "Custom RGB", "value": "_custom"]
        ]) { [weak self] value in
            guard let self else { return }
            if value as? String == "_custom" { self.customColor(p) }
            else { self.apply(p, value: value, expected: self.values[p["key"] as? String ?? ""] ?? "stock") }
        }
    }

    private func customColor(_ p: [String: Any]) {
        let original = values[p["key"] as? String ?? ""] ?? "stock"
        let hex = String(describing: original).replacingOccurrences(of: "#", with: "")
        let encoded = UInt32(hex, radix: 16) ?? 0xffffff
        var channels = [Double((encoded >> 16) & 255), Double((encoded >> 8) & 255), Double(encoded & 255)]
        let page = makeGrid(title: "Custom color", gridButtons: [button("Color", icon: "paintpalette")])
        let reference = WeakGrid(page)
        @MainActor func redraw() {
            guard let page = reference.page else { return }
            var buttons = ["Red", "Green", "Blue"].enumerated().map { index, label in
                button(label, icon: "slider.horizontal.3", value: String(Int(channels[index]))) { [weak self] in
                    self?.stagedNumber(label, value: channels[index], min: 0, max: 255, step: 1) { value in
                        channels[index] = value; redraw()
                    }
                }
            }
            buttons.append(button("Save color", icon: "checkmark") { [weak self] in
                let color = String(format: "#%02x%02x%02x", Int(channels[0]), Int(channels[1]), Int(channels[2]))
                self?.apply(p, value: color, expected: original)
            })
            updateGrid(page, buttons: buttons)
        }
        redraw(); pushTemplate(page, animated: true, completion: nil)
    }

    private func modeGroup(_ p: [String: Any], params: [[String: Any]]) {
        let page = makeGrid(title: "Longitudinal mode", gridButtons: [button("Mode", icon: "speedometer")])
        var mode = p; mode["parent_key"] = "LongitudinalControlMode"; mode["_enable_parent"] = true
        settingsPage(page, title: "Longitudinal mode", params: [mode] + params, index: 0, parent: "LongitudinalControlMode")
        pushTemplate(page, animated: true, completion: nil)
    }

    private func longitudinalMode(_ p: [String: Any]) {
        loadEditor("/api/longitudinal_mode", title: "Longitudinal mode") { [weak self] data in
            guard let self, let expected = data["values"] as? [String: Any], let current = data["mode"] as? String else { return }
            if data["locked"] as? Bool == true { self.notice(data["reason"] as? String ?? "This mode is locked."); return }
            self.values["LongitudinalControlMode"] = current
            self.choices(p, options: p["options"] as? [[String: Any]] ?? []) { [weak self] target in
                guard let self else { return }
                let experimental = String(describing: target) == "experimental"
                let label = experimental ? "Experimental mode: model-controlled gas and brakes" : "longitudinal mode"
                self.specialSave(label, endpoint: "/api/longitudinal_mode",
                    payload: ["mode": target, "expected": expected, "acknowledged": experimental],
                    checkPath: "/api/longitudinal_mode", checkKey: "values", expected: expected) { [weak self] in
                        self?.values["LongitudinalControlMode"] = target
                    }
            }
        }
    }

    private func language() {
        let options: [[String: Any]] = [
            ["value": "main_en", "label": "English"], ["value": "main_es", "label": "Spanish"],
            ["value": "main_fr", "label": "French"], ["value": "main_ko", "label": "Korean"],
            ["value": "main_zh-CHS", "label": "Chinese"]
        ]
        choices(["key": "LanguageSetting", "label": "Language", "ui_type": "dropdown",
                 "settings_tier": "simple", "data_type": "string"], options: options)
    }

    private func brightness(_ p: [String: Any]) {
        let key = p["key"] as? String ?? "", current = number(values[key]) ?? 101
        let manual = number(values[key + "Manual"]) ?? 100
        let page = makeGrid(title: p["label"] as? String, gridButtons: [
            button(current == 101 ? "Auto · selected" : "Auto", icon: "sun.max") { [weak self] in self?.apply(p, value: 101, expected: current) },
            button(current <= 100 ? "Manual · selected" : "Manual", icon: "slider.horizontal.3") { [weak self] in
                guard let self else { return }
                var control = p; control["ui_type"] = "numeric"; control["min"] = 0; control["max"] = 100; control["precision"] = 0; control["unit"] = "%"
                self.stagedNumber("Manual brightness", value: current <= 100 ? current : manual, min: 0, max: 100, step: 1) { [weak self] value in
                    self?.apply(control, value: Int(value.rounded()), expected: current)
                }
            },
            button("Auto offset", icon: "plusminus") { [weak self] in
                guard let self else { return }
                var control = p; control["key"] = key + "Offset"; control["label"] = "Auto brightness offset"
                control["ui_type"] = "numeric"; control["min"] = -30; control["max"] = 30; control["step"] = 1; control["precision"] = 0; control["unit"] = "%"
                self.numericEditor(control, original: self.number(self.values[key + "Offset"]) ?? 0)
            }
        ])
        pushTemplate(page, animated: true, completion: nil)
    }

    private func parked(_ original: String) async throws -> [String: Any] {
        let fresh = try await request("/api/params/all?galaxy_ble_settings=1") as? [String: Any] ?? [:]
        let device = try await request("/api/device/status") as? [String: Any] ?? [:]
        guard original == session, bool(fresh["IsOnroad"]) == false,
              bool(fresh["VehicleParked"]) == true, device["status"] as? String == "Parked" else {
            throw BridgeError.message("Put the vehicle in Park and reconnect before changing settings.")
        }
        return fresh
    }

    private func same(_ left: Any?, _ right: Any?) -> Bool {
        if let left = number(left), let right = number(right) { return abs(left - right) < 0.000001 }
        return String(describing: left ?? NSNull()) == String(describing: right ?? NSNull())
    }

    private func confirmation(_ message: String, perform: @escaping @MainActor () -> Void) {
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.controller?.dismissTemplate(animated: true, completion: nil) }
        let save = CPAlertAction(title: "Save", style: .default) { [weak self] _ in
            self?.controller?.dismissTemplate(animated: true, completion: nil); perform()
        }
        controller?.presentTemplate(CPAlertTemplate(titleVariants: [message], actions: [cancel, save]), animated: true, completion: nil)
    }

    private func apply(_ p: [String: Any], value: Any, expected: Any) {
        guard !busy, let key = p["key"] as? String else { return }
        let original = session, label = p["label"] as? String ?? key
        let firmware = ["IgnoreIgnitionLine", "RemoteStartBootsComma", "HKGRemoteStartBootsComma", "TeslaWakeOnCAN"].contains(key)
        let message = firmware ? "\(label) requires a Panda firmware update and device reboot. Change this setting and flash the Panda now?" :
            (p["confirm_message"] as? String ?? "\(label): \(String(describing: value))") + "\nSave while parked?"
        confirmation(message) { [weak self] in
            guard let self else { return }; self.busy = true
            self.work = Task { [weak self] in
                guard let self else { return }; defer { self.busy = false }
                do {
                    let fresh = try await self.parked(original)
                    self.mergeValues(fresh)
                    if key == "CustomPersonalities" || key.contains("PersonalityProfile") || key.contains("Jerk") {
                        let profiles = try await self.request("/api/personality_profiles") as? [String: Any] ?? [:]
                        guard profiles["migration_required"] as? Bool == false else {
                            throw BridgeError.message("Profile data needs verified migration before editing.")
                        }
                    }
                    guard self.visible(p), p["ui_type"] as? String == "action" || self.same(fresh[key], expected) else {
                        throw BridgeError.message("This setting changed. Reopen it before saving.")
                    }
                    if let disabled = p["disabled_when_key_true"] as? String, self.bool(fresh[disabled]) == true {
                        throw BridgeError.message(p["disabled_reason"] as? String ?? "Disabled by another setting.")
                    }
                    if let parent = p["parent_key"] as? String, p["_enable_parent"] as? Bool != true,
                       (parent == "LongitudinalControlMode" ? !(self.bool(fresh["ConditionalExperimental"]) == true || self.bool(fresh["ConditionalChill"]) == true) : self.bool(fresh[parent]) != true),
                       self.catalogue.flatMap({ $0["params"] as? [[String: Any]] ?? [] }).first(where: { $0["key"] as? String == parent })?["ui_type"] as? String != "group" {
                        throw BridgeError.message("Enable the parent setting first.")
                    }
                    if let required = p["requires_nonempty_key"] as? String,
                       ["", "{}"].contains(String(describing: fresh[required] ?? "")) {
                        throw BridgeError.message("Required configuration is missing.")
                    }
                    let endpoint: String, method: String, payload: [String: Any]
                    if p["ui_type"] as? String == "action" {
                        guard p["action_endpoint"] as? String == "/api/curve_speed_controller/reset" else {
                            throw BridgeError.message("This action requires its full confirmation on iPhone.")
                        }
                        endpoint = "/api/curve_speed_controller/reset"; method = "POST"; payload = [:]
                    } else {
                        if p["ui_type"] as? String == "numeric" {
                            let limits = self.bounds(p)
                            guard let n = self.number(value), n >= limits.0, n <= limits.1 else {
                                throw BridgeError.message("Value is outside Galaxy's current range.")
                            }
                        }
                        endpoint = "/api/params"; method = "PUT"
                        var body: [String: Any] = ["key": key, "value": value, "label": label]
                        if firmware { body["confirmedPandaFirmwareFlash"] = true }
                        payload = body
                    }
                    guard original == self.session else { throw BridgeError.message("Connection changed before saving.") }
                    let response = try await self.request(endpoint, method: method, body: JSONSerialization.data(withJSONObject: payload)) as? [String: Any] ?? [:]
                    self.mergeValues(fresh)
                    if p["ui_type"] as? String != "action" { self.values[key] = value }
                    if let updated = response["updated"] as? [String: Any] { self.values.merge(updated) { _, new in new } }
                    self.valuesSession = self.session; self.valuesAt = Date()
                    self.refreshSettingsPages()
                    self.notice("Saved \(label).")
                } catch { if !Task.isCancelled { self.notice(error.localizedDescription) } }
            }
        }
    }

    private func specialSave(_ label: String, endpoint: String, payload: [String: Any],
                             checkPath: String? = nil, checkKey: String? = nil, expected: Any? = nil,
                             completion: (@MainActor () -> Void)? = nil) {
        guard !busy else { return }
        let original = session
        confirmation("Save \(label) while parked?") { [weak self] in
            guard let self else { return }; self.busy = true
            self.work = Task { [weak self] in
                guard let self else { return }; defer { self.busy = false }
                do {
                    self.mergeValues(try await self.parked(original))
                    if let checkPath, let expected {
                        let latest = try await self.request(checkPath) as? [String: Any] ?? [:]
                        let actual = checkKey.map { latest[$0] ?? NSNull() } ?? latest
                        guard self.jsonEqual(actual, expected) else { throw BridgeError.message("Saved settings changed. Reopen this editor.") }
                    }
                    guard original == self.session else { throw BridgeError.message("Connection changed before saving.") }
                    _ = try await self.request(endpoint, method: "PUT", body: JSONSerialization.data(withJSONObject: payload))
                    completion?()
                    self.notice("Saved \(label).")
                } catch { if !Task.isCancelled { self.notice(error.localizedDescription) } }
            }
        }
    }

    private func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        guard let a = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys, .fragmentsAllowed]),
              let b = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys, .fragmentsAllowed]) else { return false }
        return a == b
    }

    private func loadEditor(_ path: String, title: String, show: @escaping @MainActor ([String: Any]) -> Void) {
        guard !busy else { return }
        busy = true
        let generation = session
        let loading = makeGrid(title: title, gridButtons: [button("Reading…", icon: "arrow.triangle.2.circlepath")])
        pushTemplate(loading, animated: true, completion: nil)
        work = Task { [weak self, weak loading] in
            guard let self else { return }; defer { self.busy = false }
            do {
                let data = try await self.request(path) as? [String: Any] ?? [:]
                guard generation == self.session, let loading, self.controller?.topTemplate === loading else { return }
                self.popTemplate(animated: false, completion: { _, _ in show(data) })
            } catch { if !Task.isCancelled { self.notice(error.localizedDescription) } }
        }
    }

    private func favorites() {
        loadEditor("/api/favorites/slots", title: "Favorites") { [weak self] data in
            guard let self else { return }
            let slots = data["slots"] as? [[String: Any]] ?? []
            let options = data["options"] as? [[String: Any]] ?? []
            let buttons = (0..<3).map { index in
                let slot = index < slots.count ? slots[index] : [:]
                return self.button(slot["label"] as? String ?? "Slot \(index + 1)", icon: "star") { [weak self] in
                    self?.favoriteSlot(index, slots: slots, options: options)
                }
            }
            self.pushTemplate(makeGrid(title: "Favorites", gridButtons: buttons), animated: true, completion: nil)
        }
    }

    private func favoriteSlot(_ index: Int, slots original: [[String: Any]], options: [[String: Any]]) {
        var slots = original
        while slots.count < 3 { slots.append(["enabled": false, "show_onroad": false, "key": NSNull(), "label": ""]) }
        let page = makeGrid(title: "Favorite \(index + 1)", gridButtons: [button("Favorite", icon: "star")])
        let reference = WeakGrid(page)
        @MainActor func redraw() {
            guard let page = reference.page else { return }
            let enabled = bool(slots[index]["enabled"]) == true, onroad = bool(slots[index]["show_onroad"]) == true
            updateGrid(page, buttons: [
                button("Enabled", icon: "switch.2", value: enabled ? "On" : "Off") { slots[index]["enabled"] = !enabled; redraw() },
                button("Show while driving", icon: "car.side", value: onroad ? "On" : "Off") { slots[index]["show_onroad"] = !onroad; redraw() },
                button(slots[index]["label"] as? String ?? "Choose control", icon: "switch.2") { [weak self] in
                    self?.choices(["label": "Choose favorite"], options: options.map {
                        ["label": $0["label"] ?? $0["key"] ?? "", "value": $0["key"] ?? ""]
                    }) { [weak self] key in
                        slots[index]["key"] = key
                        slots[index]["label"] = options.first { String(describing: $0["key"] ?? "") == String(describing: key) }?["label"] ?? key
                        self?.popTemplate(animated: true, completion: nil); redraw()
                    }
                },
                button("Save", icon: "checkmark") { [weak self] in
                    self?.specialSave("favorite slots", endpoint: "/api/favorites/slots", payload: ["slots": slots],
                                      checkPath: "/api/favorites/slots", checkKey: "slots", expected: original)
                }
            ])
        }
        redraw(); pushTemplate(page, animated: true, completion: nil)
    }

    private func personalities() {
        loadEditor("/api/personality_profiles", title: "Driving personalities") { [weak self] data in
            guard let self else { return }
            if data["migration_required"] as? Bool == true {
                self.notice("These profiles need Galaxy's verified migration on iPhone before editing."); return
            }
            let profiles = data["profiles"] as? [String: [String: Any]] ?? [:]
            guard !profiles.isEmpty else { self.notice("Profiles were not returned by comma."); return }
            let page = makeGrid(title: "Personalities", gridButtons: [self.button("Personalities", icon: "car.side")])
            let reference = WeakGrid(page)
            let entries = ["traffic", "aggressive", "standard", "relaxed"].flatMap { id in
                (["acceleration", "braking", "following"] + (self.bool(self.values["GalaxyDeveloperMode"]) == true ? ["advanced"] : [])).map { (id, $0) }
            }
            @MainActor func render(_ index: Int) {
                guard let page = reference.page else { return }
                let count = max(1, (entries.count + 7) / 8), current = min(index, count - 1)
                let buttons = entries.dropFirst(current * 8).prefix(8).map { id, category in
                    self.button("\(id.capitalized) \(category)", icon: category == "following" ? "car.side" : "speedometer") { [weak self] in
                        guard let self else { return }
                        if category == "advanced" {
                            let prefix = id == "traffic" ? "TrafficJerk" : id.capitalized + "Jerk"
                            let params = self.catalogue.flatMap { $0["params"] as? [[String: Any]] ?? [] }.filter { ($0["key"] as? String ?? "").hasPrefix(prefix) }
                            self.showSettings(["name": id.capitalized + " advanced", "params": params.map { p in var p = p; p["_display_root"] = true; return p }])
                        } else {
                            self.personalityCategory(id, category: category, config: profiles[id]?[category] as? [String: Any] ?? [:], data: data)
                        }
                    }
                }
                self.updateGrid(page, buttons: buttons)
                self.paging(page, index: current, count: count, change: render)
                page.leadingNavigationBarButtons = [CPBarButton(title: "Enable") { [weak self] _ in self?.profileSwitches() }]
            }
            render(0); self.pushTemplate(page, animated: true, completion: nil)
        }
    }

    private func profileSwitches() {
        let keys = ["CustomPersonalities", "TrafficPersonalityProfile", "AggressivePersonalityProfile", "StandardPersonalityProfile", "RelaxedPersonalityProfile"]
        let params = catalogue.flatMap { $0["params"] as? [[String: Any]] ?? [] }.filter { keys.contains($0["key"] as? String ?? "") }
        let page = makeGrid(title: "Enabled profiles", gridButtons: params.map { p in
            button(settingCaption(p), icon: "switch.2", value: bool(values[p["key"] as? String ?? ""]) == true ? "On" : "Off") { [weak self] in self?.edit(p) }
        })
        pushTemplate(page, animated: true, completion: nil)
    }

    private func personalityCategory(_ id: String, category: String, config: [String: Any], data: [String: Any]) {
        let options = (data["options"] as? [String: Any])?[category] as? [Any] ?? []
        let bounds = (data["bounds"] as? [String: Any])?[category] as? [Double] ?? []
        let speeds = (data["speed_breakpoints_mph"] as? [String: Any])?[category] as? [Double] ?? []
        let reference = ((data["reference_curves"] as? [String: [String: Any]])?[id])?[category] as? [Double] ?? []
        let curve = config["preset"] as? String == "custom" ? (config["curve"] as? [Double] ?? []) : reference
        guard bounds.count == 2, speeds.count == curve.count, !curve.isEmpty else { notice("Curve data or limits are unavailable."); return }
        curveEditor(id, category: category, original: config, curve: curve, speeds: speeds, bounds: bounds, presets: options, reference: reference)
    }

    private func curveEditor(_ id: String, category: String, original: [String: Any], curve saved: [Double], speeds: [Double], bounds: [Double], presets: [Any], reference presetReference: [Double]) {
        var curve = saved
        let page = makeGrid(title: category.capitalized, gridButtons: [button("Curve", icon: "chart.xyaxis.line")])
        let reference = WeakGrid(page)
        @MainActor func render(_ index: Int) {
            guard let page = reference.page else { return }
            let count = max(1, (curve.count + 7) / 8), current = min(index, count - 1)
            let buttons = Array(curve.indices.dropFirst(current * 8).prefix(8)).map { point in
                let metric = bool(values["IsMetric"]) == true
                let speed = speeds[point] * (metric ? 1.609344 : 1)
                return button(String(format: "%.0f %@", speed, metric ? "km/h" : "mph"), icon: "slider.horizontal.3") { [weak self] in
                    self?.stagedNumber(category.capitalized, value: curve[point], min: bounds[0], max: bounds[1], step: 0.05) { value in
                        curve[point] = value; render(current)
                    }
                }
            }
            updateGrid(page, buttons: buttons)
            paging(page, index: current, count: count, change: render)
            page.leadingNavigationBarButtons = [CPBarButton(title: "Preset") { [weak self] _ in
                self?.choices(["label": category.capitalized], options: presets.map { option in
                    if let option = option as? [String: Any] { return option }
                    return ["label": String(describing: option).replacingOccurrences(of: "_", with: " ").capitalized, "value": option]
                }) { [weak self] preset in
                    self?.specialSave("\(id) \(category)", endpoint: "/api/personality_profiles", payload: ["profile": id, "category": category, "preset": preset, "curve": String(describing: preset) == "custom" ? presetReference : [], "expected": original])
                }
            }, CPBarButton(title: "Save") { [weak self] _ in
                self?.specialSave("\(id) \(category)", endpoint: "/api/personality_profiles",
                    payload: ["profile": id, "category": category, "preset": "custom", "curve": curve, "expected": original])
            }]
        }
        render(0); pushTemplate(page, animated: true, completion: nil)
    }

    private func stagedNumber(_ title: String, value: Double, min lo: Double, max hi: Double, step: Double,
                              done: @escaping @MainActor (Double) -> Void) {
        var draft = value
        let page = makeGrid(title: title, gridButtons: [button("Value", icon: "slider.horizontal.3")], compact: true)
        let reference = WeakGrid(page)
        @MainActor func redraw() {
            guard let page = reference.page else { return }
            updateGrid(page, buttons: [
                button("Decrease", icon: "minus.circle") { draft = max(lo, draft - step); redraw() },
                button(String(format: "%.2f", draft), icon: "slider.horizontal.3"),
                button("Increase", icon: "plus.circle") { draft = min(hi, draft + step); redraw() },
                button("Done", icon: "checkmark") { [weak self] in
                    done(draft); self?.popTemplate(animated: true, completion: nil)
                }
            ])
        }
        redraw(); pushTemplate(page, animated: true, completion: nil)
    }

    private func refreshSettingsPages() {
        let updates = settingsRefresh.objectEnumerator()?.allObjects as? [GridRefresh] ?? []
        for update in updates { update.perform() }
    }

    private func notice(_ message: String) {
        guard controller?.presentedTemplate == nil else { return }
        let action = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.controller?.dismissTemplate(animated: true, completion: nil) }
        controller?.presentTemplate(CPAlertTemplate(titleVariants: [String(message.prefix(240))], actions: [action]), animated: true, completion: nil)
    }
}
