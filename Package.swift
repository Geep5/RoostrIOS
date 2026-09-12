// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "RoostrIOS",
	platforms: [.iOS(.v17), .macOS(.v14)],
	products: [
		.library(name: "GlonCore", targets: ["GlonCore"]),
		.library(name: "RoostrSync", targets: ["RoostrSync"]),
		.library(name: "RoostrUI", targets: ["RoostrUI"]),
		.executable(name: "roostr-mac", targets: ["RoostrMac"]),
	],
	dependencies: [
		.package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
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
		// Host for the engine's sync session: relay I/O, signing, SQLite, Keychain, the sync loop, the backend the UI consumes.
		.target(
			name: "RoostrSync",
			dependencies: ["GlonCore", .product(name: "P256K", package: "swift-secp256k1")],
			linkerSettings: [.linkedLibrary("sqlite3")]
		),
		.testTarget(
			name: "RoostrSyncTests",
			dependencies: ["RoostrSync"],
			resources: [.copy("Fixtures")]
		),
		// SwiftUI surface shared by the iOS app (App/, XcodeGen) and the macOS runner below.
		.target(name: "RoostrUI", dependencies: ["RoostrSync"]),
		.executableTarget(name: "RoostrMac", dependencies: ["RoostrUI"]),
	]
)
