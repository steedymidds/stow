import SwiftUI
import AppKit

struct SourcesView: View {
    @EnvironmentObject var store: Store
    @UIState private var editing: SourceDraft?
    private let kinds = ["google-drive": "Google Drive", "dropbox": "Dropbox", "icloud": "iCloud Drive", "box": "Box", "onedrive": "OneDrive", "local": "On this Mac"]
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 0, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sources").font(Theme.sans(44)).tracking(-1.2)
                    Spacer()
                    MonoLabel("\(store.registry.filter { $0.enabled != false }.count) connected · \(store.registry.filter { $0.enabled == false }.count) off")
                }
                Text("Every account and folder Stow knows. Connect a synced folder, an external drive or any folder on this Mac; pause one, make it private, or change what Stow may do with it.")
                    .font(Theme.sans(15)).foregroundStyle(Theme.warmGrey).frame(maxWidth: 680, alignment: .leading)
                HStack(spacing: 8) {
                    ThemeButton(title: "Connect a folder…", kind: .primary) { addFolder() }
                    ThemeButton(title: store.rebuilding ? "Rebuilding…" : "Rebuild catalogue", kind: .secondary, working: store.rebuilding) {
                        if store.allowClick() { store.rebuildCatalogue() }
                    }
                }
                if !store.rebuildLog.isEmpty {
                    Text(store.rebuildLog).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().stroke(Theme.line1, lineWidth: 1))
                }
                Rectangle().fill(Theme.line2).frame(height: 1)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(store.registry) { s in card(s) }
                }
                let live = store.detected.filter { $0.stale != true }
                let stale = store.detected.filter { $0.stale == true }
                if !live.isEmpty || !stale.isEmpty {
                    MonoLabel("Found on the Mac, not connected").padding(.top, 24)
                    ForEach(live, id: \.self) { d in
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.label ?? "").font(Theme.sans(15))
                                Text(d.path ?? "").font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            ThemeButton(title: "Connect", kind: .secondary, small: true) {
                                if let p = d.path {
                                    let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                                    editing = SourceDraft(folder: url, label: cleanLabel(d.label), taken: Set(store.registry.map(\.id)))
                                }
                            }
                        }
                        .padding(.vertical, 10)
                        Rectangle().fill(Theme.line1).frame(height: 1)
                    }
                    if !stale.isEmpty {
                        Text("\(stale.count) leftover \(stale.count == 1 ? "folder" : "folders") from re-linking Dropbox: old copies, not accounts.")
                            .font(Theme.sans(13)).foregroundStyle(Theme.muted).padding(.top, 4)
                    }
                }
            }
            .padding(30)
        }
        .sheet(item: $editing) { d in
            SourceSheet(draft: d) { editing = nil }.environmentObject(store)
        }
    }

    private func cleanLabel(_ l: String?) -> String? {
        guard let l else { return nil }
        if let r = l.range(of: " / ") { return String(l[r.upperBound...]) }
        return l
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Connect"
        panel.message = "Choose a synced cloud folder, an external drive or any folder for Stow to index."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editing = SourceDraft(folder: url, taken: Set(store.registry.map(\.id)))
    }

    private func card(_ s: Source) -> some View {
        let cat = store.sources[s.id]
        let on = s.enabled != false
        let missing = on && s.rootURL.map { !FileManager.default.fileExists(atPath: $0.path) } == true
        let role: String = s.role == "file-into" ? "Stow files into it" : s.role == "maintain" ? "Stow tidies it" : "Search only"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(!on ? Theme.olive : missing ? Theme.signal : Theme.accent).frame(width: 8, height: 8)
                MonoLabel(!on ? "Off" : missing ? "Folder missing" : "Live")
                if s.isPrivate == true { MonoLabel("Private", color: Theme.lavender) }
                Spacer()
                MonoLabel(s.id)
            }
            Text(s.name).font(Theme.sans(18, .medium))
            Text([kinds[s.kind ?? ""] ?? s.kind ?? "", s.account ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.sans(13)).foregroundStyle(Theme.warmGrey).lineLimit(2)
            Text([s.business ?? "Unassigned", role].joined(separator: " · "))
                .font(Theme.sans(13)).foregroundStyle(Theme.warmGrey)
            if let files = cat?.files {
                Text(Fmt.count(files)).font(Theme.sans(30)).tracking(-0.6)
                MonoLabel("files · \(Fmt.count(cat?.entries ?? 0)) entries")
            } else {
                Text("—").font(Theme.sans(30)).foregroundStyle(Theme.olive)
                MonoLabel(on ? "Not catalogued yet" : "Off")
            }
            HStack(spacing: 4) {
                ThemeButton(title: "Edit", kind: .secondary, small: true) {
                    editing = SourceDraft(s, exclude: SourcesIO.excludes(s.id))
                }
                if let root = s.rootURL, on, !missing {
                    ThemeButton(title: "Show in Finder", kind: .ghost, small: true) { NSWorkspace.shared.open(root) }
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 20).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line2).frame(height: 1) }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line1).frame(width: 1) }
    }
}
