import SwiftUI
import RoostrSync

/// Object list with sync status, identity footer and the new-note sheet.
struct ObjectsView: View {
	@Environment(AppModel.self) private var model
	@State private var composing = false

	var body: some View {
		NavigationStack {
			List(model.objects) { summary in
				NavigationLink(value: summary.id) {
					ObjectRow(summary: summary)
				}
			}
			.overlay {
				if model.objects.isEmpty {
					ContentUnavailableView("No notes yet", systemImage: "note.text", description: Text("Tap + to write the first one."))
				}
			}
			.navigationTitle("Notes")
			.navigationDestination(for: String.self) { id in
				ObjectView(id: id)
			}
			.toolbar {
				ToolbarItem(placement: .principal) { SyncBadge(status: model.status) }
				ToolbarItem(placement: .primaryAction) {
					Button { composing = true } label: { Label("New note", systemImage: "plus") }
				}
			}
			.safeAreaInset(edge: .bottom) { IdentityFooter() }
			.refreshable { await model.refresh() }
			.sheet(isPresented: $composing) { ComposeSheet() }
		}
	}
}

struct ObjectRow: View {
	let summary: ObjectSummary

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(summary.name.isEmpty ? "Untitled" : summary.name)
				.font(.body)
				.foregroundStyle(summary.name.isEmpty ? .secondary : .primary)
			HStack(spacing: 6) {
				Text(summary.typeKey)
				Text("·")
				Text(Date(timeIntervalSince1970: TimeInterval(summary.updatedAt)), style: .relative)
			}
			.font(.caption)
			.foregroundStyle(.secondary)
		}
		.padding(.vertical, 2)
	}
}

/// Colored dot plus a short phrase for the current `SyncStatus`.
struct SyncBadge: View {
	let status: SyncStatus

	var body: some View {
		HStack(spacing: 6) {
			Circle().fill(color).frame(width: 8, height: 8)
			Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
		}
		.help(status.detail ?? text)
	}

	private var color: Color {
		switch status.phase {
		case .idle: return .gray
		case .backfill: return .orange
		case .live: return status.pending > 0 ? .yellow : .green
		case .error: return .red
		}
	}

	private var text: String {
		switch status.phase {
		case .idle: return "Not syncing"
		case .backfill: return "Syncing… \(status.imported) imported"
		case .live: return status.pending > 0 ? "Live · \(status.pending) pending" : "Live"
		case .error: return status.detail ?? "Sync error"
		}
	}
}

struct IdentityFooter: View {
	@Environment(AppModel.self) private var model

	var body: some View {
		HStack {
			Text(model.npub)
				.font(.caption.monospaced())
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.truncationMode(.middle)
				.textSelection(.enabled)
			Spacer()
			Button("Log out", role: .destructive) { Task { await model.logout() } }
				.font(.caption)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 6)
		.background(.bar)
	}
}

struct ComposeSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var text = ""
	@State private var error: String?
	@State private var saving = false

	var body: some View {
		NavigationStack {
			Form {
				TextField("Name", text: $name)
				TextField("Text", text: $text, axis: .vertical)
					.lineLimit(6...)
				if let error {
					Text(error).font(.footnote).foregroundStyle(.red)
				}
			}
			.navigationTitle("New note")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
				ToolbarItem(placement: .confirmationAction) {
					Button("Create", action: create)
						.disabled(saving || (name.isEmpty && text.isEmpty))
				}
			}
			.disabled(saving)
		}
		.frame(minWidth: 400, minHeight: 300)
	}

	private func create() {
		saving = true
		error = nil
		Task {
			do {
				_ = try await model.createNote(name: name, text: text)
				dismiss()
			} catch {
				self.error = "\(error)"
			}
			saving = false
		}
	}
}
