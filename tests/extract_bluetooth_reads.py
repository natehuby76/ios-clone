from pathlib import Path
import sys

def method(path, name):
    source = Path(path).read_text()
    start = source.index("    static func " + name + "(")
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        if source[end] == "{": depth += 1
        if source[end] == "}": depth -= 1
        end += 1
    return source[start:end]

methods = method("GalaxyBluetooth/BluetoothTransport.swift", "useNotifications") + "\n" + method("GalaxyBluetooth/LoopbackServer.swift", "adaptNativeAsset")
tests = r'''
@main struct BluetoothReadRegression {
    static func main() {
        for path in ["/api/params/all?galaxy_ble_settings=1", "/api/device/status", "/api/params/defaults"] {
            precondition(!Probe.useNotifications(method: "GET", path: path, supported: true), "Read used stalled notification window")
        }
        precondition(Probe.useNotifications(method: "PUT", path: "/api/params", supported: true))
        precondition(!Probe.useNotifications(method: "PUT", path: "/api/params", supported: false))
        precondition(!Probe.useNotifications(method: "GET", path: "/_bridge/health", supported: true))
        let source = "api.getParams(); if (this.busy || !this.ready || this.contextPending) return; api.updateParam({key: 'IsMetric', value: true})"
        let bytes = Data(source.utf8)
        let adapted = String(data: Probe.adaptNativeAsset(bytes, path: "assets/mobile/js/components/PersonalityProfiles.js"), encoding: .utf8)!
        precondition(adapted.contains("api.getSettingsParams()"))
        precondition(adapted.contains("document.hidden"))
        precondition(adapted.contains("api.updateParam({key: 'IsMetric', value: true})"))
        precondition(Probe.adaptNativeAsset(bytes, path: "assets/mobile/js/views/Home.js") == bytes)
        print("Bluetooth read policy and native settings adaptation passed")
    }
}
'''
Path(sys.argv[1]).write_text("import Foundation\nstruct Probe {\n" + methods + "\n}\n" + tests)
