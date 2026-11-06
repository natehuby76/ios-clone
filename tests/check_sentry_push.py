from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "GalaxyBluetooth/SentryPush.swift").read_text().split("@MainActor\nfinal class SentryAppDelegate:")[0]
with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    model = directory / "SentryPush.swift"
    model.write_text(source)
    binary = directory / "regression"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(model),
                    str(root / "tests/SentryPushRegression.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
