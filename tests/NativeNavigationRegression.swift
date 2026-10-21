import Foundation

@MainActor final class NativeComma: GalaxyRequestTransport {
    var connected = true
    var response: [String: Any] = ["revision":"a", "enabled":true, "hasKey":true, "status":"noDestination", "destination":NSNull(), "routeKey":"0123456789abcdef", "route":[], "location":NSNull(), "instruction":NSNull()]
    var writes: [[String: Any]] = []
    var writeStatus = 200
    var changeConnection = false
    var afterRead: (() -> Void)?
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        if method == "GET" {
            precondition(path == "/api/navigation/status" && body.isEmpty)
            let data = try JSONSerialization.data(withJSONObject: response)
            afterRead?()
            return make(200, data)
        }
        precondition(method == "POST" && path == "/api/navigation/action")
        let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        writes.append(payload)
        precondition(Set(payload.keys) == (payload["action"] as? String == "select" ? Set(["action", "revision", "destination"]) : Set(["action", "revision"])))
        if writeStatus == 200 {
            response["destination"] = payload["destination"] ?? NSNull()
            response["revision"] = "b"
        }
        return make(writeStatus, try JSONSerialization.data(withJSONObject: response))
    }
    func make(_ status: Int, _ data: Data) -> BridgeResponse {
        BridgeResponse(id: "test", session: "test", counter: 1, status: status, headers: [:], body: data.base64EncodedString())
    }
}
@main struct NativeNavigationRegression {
    static func tryPath(_ version: String?) -> String { try! NativeNavigationAPI.statusPath(version: version) }
    @MainActor static func main() async throws {
        let comma = NativeComma()
        let destination = try NavigationDestination(name: "Test", latitude: 40, longitude: -110)
        let read = try await NativeNavigationAPI.command(.read, transport: comma, stillCurrent: { true })
        let readDestination = try NavigationCommand.activeDestination(in: read)
        precondition(readDestination == nil)
        _ = try await NativeNavigationAPI.command(.start(destination), transport: comma, stillCurrent: { true })
        precondition(comma.writes.count == 1 && comma.writes[0]["revision"] as? String == "a")
        do { _ = try await NativeNavigationAPI.command(.end, transport: comma, expectedRevision: "a", stillCurrent: { true }); preconditionFailure("Ended a replacement route") } catch {}
        precondition(comma.writes.count == 1)
        _ = try await NativeNavigationAPI.command(.end, transport: comma, expectedRevision: "b", stillCurrent: { true })
        precondition(comma.writes.count == 2)
        comma.writeStatus = 409
        do { _ = try await NativeNavigationAPI.command(.start(destination), transport: comma, stillCurrent: { true }); preconditionFailure() } catch {}
        precondition(comma.writes.count == 3, "A conflicting mutation was retried")
        comma.afterRead = { comma.changeConnection = true }
        do { _ = try await NativeNavigationAPI.command(.start(destination), transport: comma, stillCurrent: { !comma.changeConnection }); preconditionFailure() } catch {}
        precondition(comma.writes.count == 3)
        comma.afterRead = nil
        var state = comma.response
        state["destination"] = ["name":"Test", "latitude":40, "longitude":-110]
        state["status"] = "guiding"
        state["route"] = [["latitude":40, "longitude":-110], ["latitude":40.01, "longitude":-110.01]]
        state["location"] = ["latitude":40, "longitude":-110, "bearing":90, "validForMs":1000]
        state["instruction"] = ["text":"Turn left", "maneuverType":"turn", "maneuverModifier":"left", "distanceMeters":100, "remainingDistanceMeters":1000, "remainingDurationSeconds":200]
        func snapshot() throws -> CommaRouteSnapshot { try NativeNavigationAPI.snapshot(JSONSerialization.data(withJSONObject: state)) }
        let active = try snapshot()
        precondition(active.status == "active" && active.ageSeconds == 3 && active.routePoints?.count == 2 && active.position != nil)
        precondition(tryPath(active.routeVersion) == "/api/navigation/status?routeKey=0123456789abcdef")
        let completeRoute = state.removeValue(forKey: "route")!
        state["routeUnchanged"] = true
        let unchanged = try snapshot()
        precondition(unchanged.status == "active" && unchanged.routePoints == nil)
        state["route"] = completeRoute
        state.removeValue(forKey: "routeUnchanged")
        state["location"] = ["latitude":40, "longitude":-110, "bearing":90, "validForMs":0, "lastKnown":true] as [String:Any]
        let saved = try snapshot()
        precondition(saved.position == nil, "Saved coordinates shown as live")
        state["status"] = "stale"
        let stale = try snapshot()
        precondition(stale.status == "waiting")
        state["route"] = [["latitude":1000, "longitude":0]]
        do { _ = try snapshot(); preconditionFailure("Invalid geometry accepted") } catch {}
        print("Native navigation: revision barriers, no write replay, session changes, schema, freshness, geometry passed")
    }
}
