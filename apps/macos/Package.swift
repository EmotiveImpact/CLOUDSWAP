// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CloudSwap", platforms: [.macOS(.v13)],
    products: [.executable(name: "CloudSwap", targets: ["CloudSwap"])],
    targets: [.target(name: "PagingStore"), .testTarget(name: "PagingStoreTests", dependencies: ["PagingStore"]), .executableTarget(name: "CloudSwap"), .executableTarget(name: "R2Lab", dependencies: ["PagingStore"]), .testTarget(name: "R2LabTests", dependencies: ["R2Lab"])])
