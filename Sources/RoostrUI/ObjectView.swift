import SwiftUI
import GlonCore

/// Read-only rendering of one replayed object: name, text blocks in document
/// order, then the scalar fields.
struct ObjectView: View {
	@Environment(AppModel.self) private var model
	let id: String
	@State private var page: ObjectPage?
	@State private var error: String?

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 12) {
				if let page {
					Text(page.name.isEmpty ? "Untitled" : page.name).font(.title.bold())
					ForEach(page.blocks) { block in
						Text(block.text)
							.font(block.style == 0 ? .body : .headline)
							.frame(maxWidth: .infinity, alignment: .leading)
							.textSelection(.enabled)
					}
					if !page.fields.isEmpty {
						Divider().padding(.top, 8)
						Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
							ForEach(page.fields, id: \.key) { field in
								GridRow {
									Text(field.key).font(.caption.monospaced()).foregroundStyle(.secondary)
									Text(field.value).font(.caption).textSelection(.enabled)
								}
							}
						}
					}
				} else if let error {
					Text(error).foregroundStyle(.red)
				} else {
					ProgressView()
				}
			}
			.padding()
			.frame(maxWidth: .infinity, alignment: .leading)
		}
		.navigationTitle(page?.name ?? "")
		.task(id: model.objects) { await load() }
	}

	private func load() async {
		do {
			page = ObjectPage(try await model.object(id: id))
			error = nil
		} catch {
			self.error = "\(error)"
		}
	}
}

/// Projection of an ObjectJSON (unpacked maps) onto what the view shows.
struct ObjectPage {
	struct Block: Identifiable {
		let id: String
		let text: String
		let style: Int64
	}

	let name: String
	let blocks: [Block]
	let fields: [(key: String, value: String)]

	init(_ object: JSONValue) {
		guard case .object(let fields)? = object["fields"] else {
			name = ""; blocks = []; self.fields = []
			return
		}
		name = fields["name"]?["stringValue"]?.string ?? ""
		blocks = Self.textBlocks(object["blocks"])
		self.fields = fields.keys.sorted().compactMap { key in
			guard key != "name", let value = Self.scalar(fields[key]!) else { return nil }
			return (key, value)
		}
	}

	/// Document order as the website's editor computes it: roots are blocks no
	/// other block lists as a child (skipping the `__content__`/`__discussion__`
	/// containers), then depth-first through `childrenIds`.
	private static func textBlocks(_ value: JSONValue?) -> [Block] {
		guard case .array(let raw)? = value else { return [] }
		var order: [String] = []
		var byId: [String: JSONValue] = [:]
		var referenced = Set<String>()
		for block in raw {
			guard let id = block["id"]?.string else { continue }
			order.append(id)
			byId[id] = block
			if case .array(let children)? = block["childrenIds"] {
				for child in children { if let cid = child.string { referenced.insert(cid) } }
			}
		}
		var out: [Block] = []
		var seen = Set<String>()
		func visit(_ id: String) {
			guard !seen.contains(id), let block = byId[id] else { return }
			seen.insert(id)
			if let text = block["content"]?["text"] {
				out.append(Block(id: id, text: text["text"]?.string ?? "", style: text["style"].flatMap(int) ?? 0))
			}
			if case .array(let children)? = block["childrenIds"] {
				for child in children { if let cid = child.string { visit(cid) } }
			}
		}
		for id in order where !referenced.contains(id) && id != "__content__" && id != "__discussion__" {
			visit(id)
		}
		return out
	}

	private static func int(_ value: JSONValue) -> Int64? {
		switch value {
		case .int(let n): return n
		case .double(let d): return Int64(d)
		default: return nil
		}
	}

	/// Scalar ValueJSON → display string; lists, maps and links are skipped.
	private static func scalar(_ value: JSONValue) -> String? {
		if let s = value["stringValue"]?.string { return s }
		if let n = value["intValue"].flatMap(int) { return String(n) }
		if case .double(let d)? = value["floatValue"] { return String(d) }
		if case .int(let n)? = value["floatValue"] { return String(n) }
		if case .bool(let b)? = value["boolValue"] { return b ? "true" : "false" }
		return nil
	}
}
