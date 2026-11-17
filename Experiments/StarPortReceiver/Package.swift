// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StarPortReceiver",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [.library(name: "StarPortReceiver", targets: ["StarPortReceiver"])],
    targets: [
        .target(name: "StarPortReceiver"),
        .testTarget(name: "StarPortReceiverTests", dependencies: ["StarPortReceiver"])
    ]
)
