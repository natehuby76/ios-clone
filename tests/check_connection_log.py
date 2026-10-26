from pathlib import Path
import subprocess, tempfile
source = Path("GalaxyBluetooth/GalaxyBluetoothApp.swift").read_text()
start = source.index("@MainActor\nfinal class ConnectionEventLog")
end = source.index("    func report(model:", start)
probe = "import Foundation\nimport Combine\n" + source[start:end] + "}\n" + r''' 
@main struct LogRegression {
    @MainActor static func main() {
        let log = ConnectionEventLog()
        var publications = 0
        let observation = log.objectWillChange.sink { publications += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<30000 { log.record("event \(index)") }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(log.events.count == 3000)
        precondition(log.events.first!.hasSuffix("event 27000"))
        precondition(log.events.last!.hasSuffix("event 29999"))
        precondition(publications == 0, "Recording must not invalidate SwiftUI")
        log.record("repeat"); log.record("repeat"); log.record("repeat"); log.record("next")
        precondition(log.events.dropLast().last!.contains("repeated 2 additional times"))
        let secret = String(repeating: "a", count: 64)
        log.record("error https://galaxy.firestar.link/private?token=secret " + secret + " Bearer private-token")
        precondition(!log.events.last!.contains(secret))
        precondition(!log.events.last!.contains("private-token"))
        precondition(!log.events.last!.contains("galaxy.firestar.link"))
        log.clear(); precondition(log.events.isEmpty)
        log.record("fresh"); precondition(log.events.count == 1)
        withExtendedLifetime(observation) {}
        print("Connection log: ordering, bounds, redaction, repeat summary, clear, and zero UI publications passed; 30000 events in \(elapsed)s")
    }
}
'''
with tempfile.TemporaryDirectory() as folder:
    path = Path(folder)
    (path / "LogProbe.swift").write_text(probe)
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(path / "cache"), str(path / "LogProbe.swift"), "-o", str(path / "probe")], check=True)
    subprocess.run([str(path / "probe")], check=True)
