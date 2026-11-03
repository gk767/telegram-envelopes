// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TelegramEnvelopes",
    products: [.library(name: "TelegramEnvelopes", targets: ["TelegramEnvelopes"])],
    targets: [
        .target(name: "TelegramEnvelopes", path: "Sources"),
        .testTarget(name: "TelegramEnvelopesTests", dependencies: ["TelegramEnvelopes"], path: "Tests")
    ]
)
