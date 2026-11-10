// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CloudSwap", platforms: [.macOS(.v13)],
    products: [.executable(name: "CloudSwap", targets: ["CloudSwap"])],
    targets: [.executableTarget(name: "CloudSwap"), .executableTarget(name: "R2Lab"), .testTarget(name: "R2LabTests", dependencies: ["R2Lab"])])
