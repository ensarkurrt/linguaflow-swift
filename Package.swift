// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LinguaFlow",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "LinguaFlow", targets: ["LinguaFlow"])],
  targets: [
    .target(name: "LinguaFlow", resources: [.process("PrivacyInfo.xcprivacy")]),
    .testTarget(name: "LinguaFlowTests", dependencies: ["LinguaFlow"]),
  ]
)
