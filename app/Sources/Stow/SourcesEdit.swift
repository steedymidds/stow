import SwiftUI
import AppKit

struct SourceDraft: Identifiable {
    var id: String
    var label: String
    var kind: String
    var account: String
    var business: String
    var role: String
    var root: String
    var enabled: Bool
    var isPrivate: Bool
    var exclude: String
    var isNew: Bool

    static let kinds = ["google-drive", "dropbox", "icloud", "box", "onedrive", "local"]
    static let roles = [("file-into", "Stow files into it"), ("maintain", "Stow tidies it"), ("index", "Search only")]

    init(_ s: Source, exclude: [String]) {
        id = s.id; label = s.label ?? s.id; kind = s.kind ?? "local"; account = s.account ?? ""
        business = s.business ?? "Unassigned"; role = s.role ?? "index"; root = s.root ?? ""
        enabled = s.enabled != false; isPrivate = s.isPrivate == true
        self.exclude = exclude.joined(separator: "\n"); isNew = false
    }

    /// A new source from a folder on this Mac; kind and account worked out from where it lives.
    init(folder: URL, label suggested: String? = nil, taken: Set<String>) {
        let path = folder.standardizedFileURL.path
        let home = StowPaths.home.path
        var kind = "local", account = "this Mac", label = suggested ?? folder.lastPathComponent
        if let r = path.range(of: "/Library/CloudStorage/") {
            let top = path[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            if top.hasPrefix("GoogleDrive-") { kind = "google-drive"; account = String(top.dropFirst("GoogleDrive-".count)) }
            else if top.hasPrefix("Dropbox") { kind = "dropbox"; account = top }
            else if top.hasPrefix("Box") { kind = "box"; account = top }
            else if top.hasPrefix("OneDrive") { kind = "onedrive"; account = top }
            else { account = top }
        } else if path.contains("/Mobile Documents/com~apple~CloudDocs") {
            kind = "icloud"; account = "Apple ID on this Mac"
            if suggested == nil && path.hasSuffix("com~apple~CloudDocs") { label = "iCloud Drive" }
        } else if path.hasPrefix("/Volumes/") {
            let vol = path.split(separator: "/").dropFirst().first.map(String.init) ?? "drive"
            account = "Drive: " + vol
        }
        id = SourceDraft.suggestId(label, taken: taken)
        self.label = label; self.kind = kind; self.account = account
        business = "Unassigned"; role = "index"
        root = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        enabled = true; isPrivate = kind == "local" || kind == "icloud"
        exclude = "_To Delete"; isNew = true
    }

    static func suggestId(_ label: String, taken: Set<String>) -> String {
        let words = label.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var base = words.prefix(4).compactMap { $0.first.map(String.init) }.joined()
        if base.count < 2 { base = String(label.uppercased().filter { $0.isLetter }.prefix(4)) }
        if base.isEmpty || !(base.first?.isLetter ?? false) { base = "SRC" }
        var id = base, n = 2
        while taken.contains(id) { id = base + String(n); n += 1 }
        return id
    }
}

enum SourcesIO {
    /// Writes one source into sources.json, keeping every other entry and field.
    static func save(_ d: SourceDraft) throws {
        let url = StowPaths.sources
        let data = try Data(contentsOf: url)
        guard var root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var list = root["sources"] as? [[String: Any]] else { throw EngineError.tool("sources.json isn't in the expected shape.") }
        // One backup a day before the first change.
        let stamp = Date().formatted(.iso8601.year().month().day())
        let bak = StowPaths.stowHome.appendingPathComponent("sources.json.bak-" + stamp)
        if !FileManager.default.fileExists(atPath: bak.path) { try? data.write(to: bak) }

        let ex = d.exclude.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if d.isNew {
            if list.contains(where: { ($0["id"] as? String) == d.id }) { throw EngineError.tool("There's already a source with the id \(d.id).") }
            list.append(["id": d.id, "label": d.label, "kind": d.kind, "account": d.account, "business": d.business,
                         "via": "mac", "root": d.root, "role": d.role, "enabled": d.enabled, "private": d.isPrivate,
                         "exclude": ex, "added": stamp, "added_by": "Stow app"])
        } else {
            guard let i = list.firstIndex(where: { ($0["id"] as? String) == d.id }) else { throw EngineError.tool("Source \(d.id) is no longer in sources.json.") }
            list[i]["label"] = d.label
            list[i]["business"] = d.business
            list[i]["role"] = d.role
            list[i]["enabled"] = d.enabled
            list[i]["private"] = d.isPrivate
            list[i]["exclude"] = ex
            if !d.account.isEmpty { list[i]["account"] = d.account }
        }
        root["sources"] = list
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    static func excludes(_ id: String) -> [String] {
        guard let data = try? Data(contentsOf: StowPaths.sources),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["sources"] as? [[String: Any]],
              let s = list.first(where: { ($0["id"] as? String) == id }) else { return [] }
        return s["exclude"] as? [String] ?? []
    }
}

extension Store {
    func rebuildCatalogue() {
        guard !rebuilding else { return }
        rebuilding = true
        rebuildLog = "Indexing every connected source…"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["catalogue.py", "--merge"]
            p.currentDirectoryURL = StowPaths.stowHome
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            var text = ""
            do {
                try p.run()
                text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                p.waitUntilExit()
                if p.terminationStatus != 0 { text = "The catalogue rebuild failed.\n" + text }
            } catch { text = "Couldn't run the catalogue builder: \(error.localizedDescription)" }
            DispatchQueue.main.async {
                self.rebuildLog = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.rebuilding = false
                self.load()
                let summary = text.split(separator: "\n").last.map(String.init) ?? ""
                if text.hasPrefix("The catalogue rebuild failed") || text.hasPrefix("Couldn't") {
                    self.toast("Catalogue rebuild failed", .error, detail: String(text.prefix(300)))
                } else {
                    self.toast("Catalogue rebuilt", .success, detail: summary.replacingOccurrences(of: "published rows:", with: "Shared:").replacingOccurrences(of: "private rows:", with: "· private:"))
                }
            }
        }
    }

    func saveSource(_ d: SourceDraft) -> String? {
        do {
            try SourcesIO.save(d)
            toast(d.isNew ? "Connected \(d.label)" : "Saved \(d.label)", .success, detail: "Rebuilding the catalogue…")
            rebuildCatalogue()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct SourceSheet: View {
    @EnvironmentObject var store: Store
    @UIState var draft: SourceDraft
    let close: () -> Void
    @UIState private var problem: String?
    @UIState private var customBusiness = ""

    private var businesses: [String] {
        var b = ["Work", "Personal", "Unassigned"]
        for s in store.registry { if let x = s.business, !b.contains(x) { b.append(x) } }
        return b
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MonoLabel(draft.isNew ? "Connect a source" : "Edit source")
            Text(draft.isNew ? "New source" : draft.label).font(Theme.sans(24, .medium))
            Text(draft.root).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    MonoLabel("Name")
                    TextField("", text: $draft.label).textFieldStyle(.roundedBorder)
                }
                if draft.isNew {
                    GridRow {
                        MonoLabel("Short id")
                        TextField("", text: $draft.id).textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    GridRow {
                        MonoLabel("Kind")
                        Picker("", selection: $draft.kind) { ForEach(SourceDraft.kinds, id: \.self) { Text($0).tag($0) } }
                            .labelsHidden().frame(width: 200)
                    }
                }
                GridRow {
                    MonoLabel("Account")
                    TextField("", text: $draft.account).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    MonoLabel("Business")
                    HStack {
                        Picker("", selection: $draft.business) { ForEach(businesses, id: \.self) { Text($0).tag($0) } }
                            .labelsHidden().frame(width: 200)
                        TextField("or a new one", text: $customBusiness).textFieldStyle(.roundedBorder)
                            .onSubmit { if !customBusiness.isEmpty { draft.business = customBusiness } }
                    }
                }
                GridRow {
                    MonoLabel("Job")
                    Picker("", selection: $draft.role) { ForEach(SourceDraft.roles, id: \.0) { Text($0.1).tag($0.0) } }
                        .labelsHidden().frame(width: 200)
                }
                GridRow {
                    MonoLabel("Switches")
                    HStack(spacing: 20) {
                        Toggle("Connected", isOn: $draft.enabled)
                        Toggle("Private (never on the web page)", isOn: $draft.isPrivate)
                    }
                }
                GridRow(alignment: .top) {
                    MonoLabel("Skip folders")
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $draft.exclude).font(Theme.mono(12)).frame(height: 70)
                            .scrollContentBackground(.hidden).background(Theme.surface)
                        Text("One folder name or path per line.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            Text(draft.role == "file-into" ? "The organiser may file new files into this source." :
                 draft.role == "maintain" ? "Stow tidies and searches it, but never files new things into it." :
                 "Searchable only; Stow never changes it.")
                .font(Theme.sans(13)).foregroundStyle(Theme.warmGrey)
            if let problem { Text(problem).font(Theme.sans(13)).foregroundStyle(Theme.signal) }
            HStack {
                Spacer()
                ThemeButton(title: "Cancel", kind: .ghost, action: close)
                ThemeButton(title: draft.isNew ? "Connect  →" : "Save  →", kind: .primary) { save() }
            }
        }
        .padding(28)
        .frame(width: 640)
        .background(Theme.void)
        .foregroundStyle(Theme.paper)
    }

    private func save() {
        if !customBusiness.trimmingCharacters(in: .whitespaces).isEmpty { draft.business = customBusiness.trimmingCharacters(in: .whitespaces) }
        draft.id = draft.id.uppercased().trimmingCharacters(in: .whitespaces)
        if draft.label.trimmingCharacters(in: .whitespaces).isEmpty { problem = "Give it a name."; return }
        if draft.isNew {
            if draft.id.range(of: "^[A-Z][A-Z0-9]{1,7}$", options: .regularExpression) == nil {
                problem = "The short id is 2–8 capital letters or digits, starting with a letter."; return
            }
            if store.registry.contains(where: { $0.id == draft.id }) { problem = "\(draft.id) is taken."; return }
            let real = URL(fileURLWithPath: (draft.root as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
            if store.registry.contains(where: { $0.rootURL?.resolvingSymlinksInPath().path == real }) {
                problem = "That folder is already a source."; return
            }
        }
        if let err = store.saveSource(draft) { problem = err } else { close() }
    }
}
