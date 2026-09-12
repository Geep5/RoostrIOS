// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "RoostrIOS",
	platforms: [.iOS(.v17), .macOS(.v14)],
	products: [
		.library(name: "GlonCore", targets: ["GlonCore"]),
	],
	targets: [
		// Odin engine built by glonOdin/build-xcframework.mjs; Vendor/glon-core.json fingerprints its sources.
		.binaryTarget(name: "Glon", path: "Vendor/Glon.xcframework"),
		.target(name: "GlonCore", dependencies: ["Glon"]),
		.testTarget(
			name: "GlonCoreTests",
			dependencies: ["GlonCore"],
			resources: [.copy("Fixtures")]
		),
	]
)
