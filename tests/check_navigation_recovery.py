"""Exercise the production monitor's identity gate after a network handoff."""
from pathlib import Path
import subprocess
import tempfile

source = Path('GalaxyBluetooth/Navigation/NavigationModel.swift').read_text()
start = source.index('                // A route handoff')
end = source.index('                let requestedAt = Date()', start)
gate = source[start:end]
harness = r'''
import Foundation
@MainActor final class Connection {
    var identity = "comma-a"
    var verified = false
    var checks = 0
    var onCheck: (() -> Void)?
    func ensureDeviceIdentity() async throws -> String {
        checks += 1; verified = true; onCheck?(); return identity
    }
}
@MainActor final class Monitor {
    var revision = 0
    var navigating = true
    var usingComma = true
    var commaIdentity = "comma-a"
    var accepted = false
    var rejected = false
    func clearCommaDisplay(_ message: String, discardRoute: Bool) { rejected = true }
    func step(_ connection: Connection) async throws {
        for _ in 0..<1 {
            let revision = self.revision
__GATE__
            accepted = true
        }
    }
}
@main struct Regression {
    @MainActor static func main() async throws {
        let connection = Connection(), recovered = Monitor()
        try await recovered.step(connection)
        precondition(recovered.accepted && connection.verified && connection.checks == 1,
                     "Same comma must recover after its verification cache is invalidated")
        let other = Monitor(); connection.identity = "comma-b"
        try await other.step(connection)
        precondition(other.rejected && !other.accepted, "Never adopt another comma's route")
        let reset = Monitor(); connection.identity = "comma-a"
        connection.onCheck = { reset.revision += 1; reset.navigating = false }
        try await reset.step(connection)
        precondition(!reset.accepted && !reset.rejected, "Reset must invalidate pending verification")
        print("Navigation recovery: same comma, different comma, and reset during verification passed")
    }
}
'''.replace('__GATE__', gate)
with tempfile.TemporaryDirectory() as d:
    root = Path(d)
    (root / 'Probe.swift').write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(root / 'cache'), str(root / 'Probe.swift'), '-o', str(root / 'probe')], check=True)
    subprocess.run([str(root / 'probe')], check=True)
