import SwiftUI
import GlonCore

@main
struct RoostrApp: App {
	var body: some Scene {
		WindowGroup { EngineStatusView() }
	}
}

/// Boot check: the linked Odin engine answers through the bridge on-device.
struct EngineStatusView: View {
	@State private var status = "Starting engine…"

	var body: some View {
		VStack(spacing: 12) {
			Text("Roostr").font(.largeTitle.bold())
			Text(status).font(.footnote.monospaced()).multilineTextAlignment(.center)
		}
		.padding()
		.task {
			struct Hash: Encodable { let action = "hash"; let change: [String: JSONValue] }
			let change: [String: JSONValue] = [
				"objectId": .string("boot"), "parentIds": .array([]), "timestamp": .int(0), "author": .string("ios"),
				"ops": .array([.object(["objectCreate": .object(["typeKey": .string("page")])])]),
			]
			do {
				let id: String = try await GlonCore.shared.call("codec", Hash(change: change))
				status = "engine ABI \(GlonCore.abiVersion)\nsample content address\n\(id)"
			} catch {
				status = "engine error: \(error)"
			}
		}
	}
}
