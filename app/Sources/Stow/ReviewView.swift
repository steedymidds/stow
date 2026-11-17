import SwiftUI
import AppKit

struct ReviewView: View {
    @EnvironmentObject var store: Store
    @UIState private var filter = "open"
    @UIState private var elsewhere: ReviewItem?

    private func list(_ q: ReviewQueue) -> [ReviewItem] {
        switch filter {
        case "open": return q.items.filter { $0.status == "open" || store.sessionDone.contains($0.id) }
        case "kept": return q.kept
        default: return q.done.sorted { ($0.result?.at ?? "") > ($1.result?.at ?? "") }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Review").font(Theme.sans(44)).tracking(-1.2)
                    Spacer()
                    Text("\(store.review?.open.count ?? 0) to do".uppercased())
                        .font(Theme.mono(11)).tracking(0.9).foregroundStyle(Theme.muted)
                        .contentTransition(.numericText())
                        .animation(.spring, value: store.review?.open.count)
                }
                Text("Files the organiser couldn't place with confidence. Filing makes a checked copy, then the original goes to _Review's _To Delete. Everything can be undone (⌘Z).")
                    .font(Theme.sans(15)).foregroundStyle(Theme.warmGrey)
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.top, 8).padding(.bottom, 16)
                HStack(spacing: 8) {
                    Chip(title: "To do", on: filter == "open") { filter = "open" }
                    Chip(title: "Kept", on: filter == "kept") { filter = "kept" }
                    Chip(title: "Done", on: filter == "done") { filter = "done" }
                    Spacer()
                    if filter == "open", !store.sessionDone.isEmpty {
                        ThemeButton(title: "Clear \(store.sessionDone.count) done", kind: .ghost, small: true) {
                            withAnimation(.easeOut(duration: 0.2)) { store.sessionDone.removeAll() }
                        }
                    }
                }
                .padding(.bottom, 16)
                Rectangle().fill(Theme.line2).frame(height: 1)
                if let q = store.review {
                    let items = list(q)
                    if items.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            if filter == "open" {
                                Text("All clear.").font(Theme.sans(22, .medium))
                                Text("The organiser adds new items here after each run.").font(Theme.sans(15)).foregroundStyle(Theme.warmGrey)
                            } else {
                                Text("Nothing here yet.").font(Theme.sans(15)).foregroundStyle(Theme.warmGrey)
                            }
                        }
                        .padding(.vertical, 28)
                    }
                    ForEach(items) { item in
                        Group {
                            if store.sessionDone.contains(item.id) && item.status != "open" && filter == "open" {
                                DoneStrip(item: item)
                            } else {
                                ReviewRow(item: item, onElsewhere: { elsewhere = item })
                            }
                        }
                        .transition(.opacity)
                        Rectangle().fill(Theme.line2).frame(height: 1)
                    }
                } else {
                    Text("No review queue found at Documents/.file-organiser/review/review.json.")
                        .font(Theme.sans(15)).foregroundStyle(Theme.warmGrey).padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 28)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.sessionDone)
        }
        .sheet(item: $elsewhere) { item in
            ElsewhereSheet(item: item) { source, dir in
                elsewhere = nil
                store.lastClick = .distantPast
                store.start(item, .file(source: source, dir: dir))
            } cancel: { elsewhere = nil }
            .environmentObject(store)
        }
    }
}

/// A finished item stays where it was (so the next item never slides under the pointer), collapsed, with Undo.
struct DoneStrip: View {
    @EnvironmentObject var store: Store
    let item: ReviewItem
    var body: some View {
        let r = item.result
        HStack(spacing: 12) {
            Image(systemName: item.status == "binned" ? "trash.circle.fill" : item.status == "kept" ? "pin.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 18)).foregroundStyle(item.status == "binned" ? Theme.warmGrey : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.warmGrey).strikethrough(item.status == "binned", color: Theme.olive)
                Text(line(r)).font(Theme.sans(13)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let b = store.busy[item.id] {
                ProgressView().controlSize(.small)
                Text(b).font(Theme.mono(11)).foregroundStyle(Theme.paper)
            } else {
                if item.status == "filed", let s = r?.source, let d = r?.dir, let url = store.rootURL(s)?.appendingPathComponent(d) {
                    ThemeButton(title: "Show", kind: .ghost, small: true) { NSWorkspace.shared.open(url) }
                }
                ThemeButton(title: "Undo", kind: .secondary, small: true) { Task { await store.undo(item.id) } }
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 8)
        .background(Theme.surface.opacity(0.35))
    }
    private func line(_ r: ReviewResult?) -> String {
        switch item.status {
        case "filed": return "Filed to \(store.sourceName(r?.source)) / \(r?.dir ?? "") · \(r?.ok ?? item.files.count) files"
        case "binned": return "Binned · recoverable from _Review / _To Delete"
        case "kept": return "Kept in _Review · not asked again"
        default: return item.status
        }
    }
}

struct ReviewRow: View {
    @EnvironmentObject var store: Store
    let item: ReviewItem
    let onElsewhere: () -> Void
    @UIState private var showFiles = false
    @UIState private var confirmBin = false

    var body: some View {
        let busy = store.busy[item.id]
        let sug = item.suggest
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(item.title).font(Theme.sans(19, .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                MonoLabel([item.kind ?? "", Fmt.size(item.bytes), item.when.map { "from " + $0 } ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            }
            if let why = item.why {
                Text(why).font(Theme.sans(15)).foregroundStyle(Theme.warmGrey)
                    .frame(maxWidth: 700, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if item.status == "open" {
                HStack(spacing: 8) {
                    MonoLabel("Suggested", color: Theme.accent)
                    Text(sug?.action == "trash" ? "Bin it" : (sug?.label ?? "")).font(Theme.sans(14))
                }
                if let busy {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: store.progress[item.id] ?? 0)
                            .progressViewStyle(.linear).tint(Theme.accent).frame(maxWidth: 520)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(busy).font(Theme.mono(12)).foregroundStyle(Theme.paper).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.top, 6)
                    .transition(.opacity)
                } else {
                    HStack(spacing: 8) {
                        if sug?.action == "trash" {
                            ThemeButton(title: "Bin  →", kind: .bin) { store.start(item, .bin) }
                        } else if let s = sug?.source, let d = sug?.dir {
                            ThemeButton(title: "File as suggested  →", kind: .primary) { store.start(item, .file(source: s, dir: d)) }
                        }
                        ThemeButton(title: "File elsewhere", kind: .secondary) { if store.allowClick() { onElsewhere() } }
                        if sug?.action != "trash" {
                            // Binning against the suggestion takes a second click.
                            ThemeButton(title: confirmBin ? "Click again to bin" : "Bin", kind: .bin) {
                                if confirmBin { confirmBin = false; store.start(item, .bin) }
                                else if store.allowClick() {
                                    withAnimation(.easeOut(duration: 0.15)) { confirmBin = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { confirmBin = false } }
                                }
                            }
                        }
                        ThemeButton(title: "Keep in _Review", kind: .ghost) { store.keep(item) }
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                }
                if busy == nil, let last = item.last, let f = last.failed, !f.isEmpty {
                    Text("Last try: \(f.count) didn't move. \(f.first!.err)")
                        .font(Theme.sans(13)).foregroundStyle(Theme.signal)
                }
            } else {
                doneLine
            }
            DisclosureGroup(isExpanded: $showFiles) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(item.files, id: \.p) { f in
                        HStack(spacing: 12) {
                            Text(f.p).font(Theme.sans(13)).foregroundStyle(Theme.warmGrey)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.size(f.b)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            if item.status == "open" || item.status == "kept" {
                                Button("Open") { store.quickLook(f) }.buttonStyle(.link).font(Theme.mono(11))
                                Button("Show") { store.revealInReview(f) }.buttonStyle(.link).font(Theme.mono(11))
                            }
                        }
                        .padding(.vertical, 5)
                        Rectangle().fill(Theme.line1).frame(height: 1)
                    }
                }
                .padding(.top, 4)
            } label: {
                MonoLabel(item.files.count == 1 ? "1 file" : "\(item.files.count) files")
            }
            .tint(Theme.muted)
        }
        .padding(.vertical, 20).padding(.horizontal, 8)
        .background(busy == nil ? Color.clear : Theme.surface.opacity(0.5))
        .overlay(alignment: .leading) { if busy != nil { Rectangle().fill(Theme.accent).frame(width: 2) } }
        .allowsHitTesting(busy == nil || true)
        .animation(.easeOut(duration: 0.15), value: busy)
    }

    @ViewBuilder private var doneLine: some View {
        let r = item.result
        HStack(spacing: 8) {
            switch item.status {
            case "filed":
                Text("Filed to ").foregroundStyle(Theme.warmGrey) + Text("\(store.sourceName(r?.source)) / \(r?.dir ?? "")")
            case "binned":
                Text("Binned").foregroundStyle(Theme.paper) + Text(" · in _Review / _To Delete, recoverable").foregroundStyle(Theme.warmGrey)
            case "kept":
                Text("Kept in _Review").foregroundStyle(Theme.paper) + Text(" · not asked again").foregroundStyle(Theme.warmGrey)
            default:
                Text(item.status.capitalized).foregroundStyle(Theme.warmGrey)
            }
            if let at = r?.at, let d = ISO8601DateFormatter.flexible(at) {
                MonoLabel(d.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
            }
            Spacer()
            if store.busy[item.id] != nil {
                ProgressView().controlSize(.small)
            } else if item.status == "kept" || !(r?.undo ?? []).isEmpty {
                ThemeButton(title: item.status == "kept" ? "Back to To do" : "Undo", kind: .secondary, small: true) {
                    Task { await store.undo(item.id) }
                }
            }
        }
        .font(Theme.sans(14))
    }
}

struct ElsewhereSheet: View {
    @EnvironmentObject var store: Store
    let item: ReviewItem
    let go: (String, String) -> Void
    let cancel: () -> Void
    @UIState private var source = "LU"
    @UIState private var dir = ""
    @UIState private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MonoLabel("File elsewhere")
            Text(item.title).font(Theme.sans(22, .medium))
            VStack(alignment: .leading, spacing: 6) {
                MonoLabel("Source")
                Picker("", selection: $source) {
                    ForEach(store.fileIntoSources) { s in Text(s.name).tag(s.id) }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                MonoLabel("Folder inside it")
                HStack {
                    TextField("01 Work/Brand/Images/2026-11", text: $dir)
                        .textFieldStyle(.roundedBorder).font(Theme.sans(14))
                    ThemeButton(title: "Choose…", kind: .secondary, small: true) { choose() }
                }
                Text("Missing folders are created. Files keep their names; folders inside the item keep their layout.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            if let problem { Text(problem).font(Theme.sans(13)).foregroundStyle(Theme.signal) }
            HStack {
                Spacer()
                ThemeButton(title: "Cancel", kind: .ghost, action: cancel)
                ThemeButton(title: "File here  →", kind: .primary) {
                    let d = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    if d.isEmpty { problem = "Pick or type a folder." } else { go(source, d) }
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Theme.void)
        .foregroundStyle(Theme.paper)
        .onAppear {
            source = item.suggest?.source ?? store.fileIntoSources.first?.id ?? "LU"
            dir = item.suggest?.dir ?? ""
        }
    }

    private func choose() {
        guard let root = store.rootURL(source) else { problem = "That source has no folder on this Mac."; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let start = root.appendingPathComponent(dir)
        panel.directoryURL = FileManager.default.fileExists(atPath: start.path) ? start : root
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let r = root.standardizedFileURL.path, u = url.standardizedFileURL.path
        if u == r { dir = ""; problem = "Choose a folder inside \(store.sourceName(source))."; return }
        guard u.hasPrefix(r + "/") else { problem = "That folder isn't inside \(store.sourceName(source))."; return }
        dir = String(u.dropFirst(r.count + 1)); problem = nil
    }
}
