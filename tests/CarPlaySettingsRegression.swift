import Foundation

@main
struct SettingsRegression {
    static func main() throws {
        let source = CommandLine.arguments[1]
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let catalogue = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let probe = SettingsProbe()
        let prepared = probe.prepareCatalogue(catalogue)
        precondition(prepared.count == 11)
        precondition(prepared.last?["name"] as? String == "Language")
        let params = prepared.flatMap { $0["params"] as? [[String: Any]] ?? [] }
        precondition(params.contains { $0["key"] as? String == "LanguageSetting" })
        precondition(params.filter { $0["key"] as? String == "LongitudinalControlMode" }.count == 1)
        precondition(!params.contains { ["ExperimentalMode", "ConditionalChill", "ConditionalExperimental"].contains($0["key"] as? String ?? "") })
        func param(_ key: String) -> [String: Any] { params.first { $0["key"] as? String == key }! }
        probe.mergeValues(["IsMetric": true, "GalaxyDeveloperMode": true, "CarMake": "Toyota", "HasRadar": false, "ConditionalExperimental": true])
        precondition(probe.values["LongitudinalControlMode"] as? String == "conditional_experimental")
        precondition(probe.bounds(param("MinimumLaneChangeSpeed")).1 == 150)
        probe.values["IsMetric"] = false
        precondition(probe.bounds(param("MinimumLaneChangeSpeed")).1 == 99)
        precondition(!probe.visible(param("SubaruAvhStartup")))
        precondition(!probe.visible(param("HumanLaneChanges")))
        precondition(!probe.visible(param("CustomAccelProfile")))
        let point = param("CustomAccelProfilePoint10Accel")
        probe.values["CustomAccelProfilePointCount"] = 3
        precondition(!probe.visible(point))
        probe.values["CustomAccelProfilePointCount"] = 10
        precondition(probe.visible(point))
        precondition(param("CustomAccelProfilePoint1Accel")["parent_key"] as? String == "CustomAccelProfile")
        probe.values["SteerKPStock"] = 1.26
        let kp = probe.bounds(param("SteerKP"))
        precondition(abs(kp.0 - 0.63) < 0.0001 && abs(kp.1 - 1.89) < 0.0001 && kp.2 == 0.01)
        precondition(probe.bool("false") == false && probe.bool("1") == true && probe.bool("unknown") == nil)
        precondition(probe.jsonEqual(["a": 1, "b": [2, 3]], ["b": [2, 3], "a": 1]))
        precondition(!probe.jsonEqual([1, 2], [2, 1]))
        precondition(probe.visible(["key": "StarPilotFavoriteSlots", "settings_tier": "advanced"]))
        probe.values["GalaxyDeveloperMode"] = false
        precondition(!probe.visible(param("SteerKP")))
        print("CarPlay settings regression checks passed.")
    }
}
