from pathlib import Path
import sys

source = Path('GalaxyBluetooth/LANDiscovery.swift').read_text()
def method(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

stubs = '''
import Foundation
final class Service { var delegate: AnyObject?; func stop() {} }
@MainActor final class DiscoveryProbe {
    var appActive = true, resumeWhenActive = false, searching = false
    var retriedServices = Set<String>()
    var starts = 0
    var status = ""
    var devices: [String] = []
    var browser: Service?
    var services: [String: Service] = [:]
    var deadline: Task<Void, Never>?
    func searchFailed() { pauseAfterSearchFailure() }
    func start() { stop(); starts += 1; searching = true }
'''
tests = '''
}
@main struct DiscoveryLifecycleRegression {
    @MainActor static func main() {
        let d = DiscoveryProbe()
        d.start()
        d.setActive(false)
        d.setActive(false)
        precondition(!d.searching)
        d.networkChanged()
        precondition(d.starts == 1, "Do not browse while permission UI has suspended the app")
        d.setActive(true)
        precondition(d.searching && d.starts == 2, "Resume first-use discovery without a paired identity")
        d.setActive(true)
        precondition(d.starts == 2, "Repeated active events must not reset the timeout")
        d.networkChanged()
        precondition(d.searching && d.starts == 3)
        d.setActive(false)
        d.stop()
        d.setActive(true)
        precondition(!d.searching && d.starts == 3, "Explicit Stop cancels pending resume")
        d.networkChanged()
        precondition(!d.searching, "Network changes must not restart a finished or cancelled search")
        let failed = DiscoveryProbe()
        failed.start()
        failed.searchFailed()
        failed.setActive(false)
        failed.setActive(true)
        precondition(failed.searching && failed.starts == 2,
                     "A browser failure before the permission prompt must preserve search intent")
        failed.searchFailed()
        failed.stop()
        failed.setActive(false)
        failed.setActive(true)
        precondition(!failed.searching && failed.starts == 2,
                     "Explicit Stop must cancel a permission-related retry")
        print("Discovery lifecycle: permission interruption, network change, duplicate events and explicit stop passed")
    }
}
'''
Path(sys.argv[1]).write_text(stubs + '\n'.join(method(s) for s in ['    func setActive(', '    func stop()', '    func networkChanged()', '    private func pauseAfterSearchFailure()']) + tests)
