import SwiftUI

/// Generate a key or paste an existing `nsec`/hex secret.
struct IdentityView: View {
	@Environment(AppModel.self) private var model
	@State private var secret = ""
	@State private var busy = false

	var body: some View {
		VStack(spacing: 16) {
			Text("Roostr").font(.largeTitle.bold())
			Text("Notes live under your Nostr key. Generate a new one or paste an existing secret.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)

			Button("Generate a new key") {
				Task { await run { await model.generateKey() } }
			}
			.buttonStyle(.borderedProminent)

			Divider()

			SecureField("nsec1… or 64 hex characters", text: $secret)
				.textFieldStyle(.roundedBorder)
				.autocorrectionDisabled()
				.onSubmit(importKey)
			Button("Use this key", action: importKey)
				.disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

			if let error = model.lastError {
				Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
			}
		}
		.disabled(busy)
		.padding(24)
		.frame(maxWidth: 420)
	}

	private func importKey() {
		let text = secret
		Task { await run { await model.importKey(text) } }
	}

	private func run(_ work: () async -> Void) async {
		busy = true
		model.lastError = nil
		await work()
		busy = false
		if model.key != nil { secret = "" }
	}
}
