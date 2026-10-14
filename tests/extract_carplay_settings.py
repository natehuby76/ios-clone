import pathlib, sys
source = pathlib.Path("GalaxyBluetooth/CarPlaySceneDelegate.swift").read_text()
methods = []
for name in ["bool", "number", "prepareCatalogue", "visible", "parameter", "bounds", "jsonEqual", "mergeValues"]:
    start = source.index("    private func " + name + "(")
    pos = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[pos] == "{") - (source[pos] == "}")
        pos += 1
    methods.append(source[start:pos].replace("private func", "func", 1))
pathlib.Path(sys.argv[1]).write_text("import Foundation\nfinal class SettingsProbe {\nvar values: [String: Any] = [:]\n" + "\n".join(methods) + "\n}\n")
