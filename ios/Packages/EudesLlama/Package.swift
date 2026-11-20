// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The official binary contains iPhone but not Simulator. The test setup builds
// the missing simulator slice from the exact same upstream revision.
let localFramework = "Artifacts/llama-b12236.xcframework"
let localURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(localFramework)
let llamaTarget: Target = FileManager.default.fileExists(atPath: localURL.path)
    ? .binaryTarget(name: "llama", path: localFramework)
    : .binaryTarget(name: "llama",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b12236/llama-b12236-xcframework.zip?download=1",
        checksum: "1c8c4848d37ac04f0ecd961b65824e9357f0fdc258a18e115d1fb91160861b08")

let package = Package(name: "EudesLlama", platforms: [.iOS(.v16)],
    products: [.library(name: "EudesLlama", targets: ["llama"])], targets: [llamaTarget])
