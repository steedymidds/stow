import SwiftUI
import AppKit

struct RunsView: View {
    @EnvironmentObject var store: Store
    @UIState private var selected: URL?
    @UIState private var text = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Runs").font(Theme.sans(44)).tracking(-1.2)
                    OrganisePanel()
                    Rectangle().fill(Theme.line2).frame(height: 1)
                    if let r = store.run {
                        latest(r)
                    } else {
                        Text("No run report yet.").font(Theme.sans(15)).foregroundStyle(Theme.warmGrey)
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380, idealWidth: 480, maxWidth: 600)
            Rectangle().fill(Theme.line2).frame(width: 1)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    MonoLabel("Run log")
                    Spacer()
                    Picker("", selection: $selected) {
                        ForEach(store.logs, id: \.self) { u in Text(u.deletingPathExtension().lastPathComponent).tag(URL?.some(u)) }
                    }
                    .labelsHidden().frame(width: 160)
                    if let s = selected {
                        ThemeButton(title: "Show in Finder", kind: .ghost, small: true) { NSWorkspace.shared.activateFileViewerSelecting([s]) }
                    }
                }
                ScrollView {
                    Text(attributed(text))
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.warmGrey)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(30)
        }
        .onAppear { if selected == nil { selected = store.logs.first }; loadLog() }
        .onChange(of: store.logs) { _, logs in if selected == nil || !logs.contains(selected!) { selected = logs.first }; loadLog() }
        .onChange(of: selected) { _, _ in loadLog() }
    }

    private func loadLog() {
        guard let s = selected else { text = ""; return }
        text = (try? String(contentsOf: s, encoding: .utf8)) ?? "Couldn't read \(s.lastPathComponent)."
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    @ViewBuilder private func latest(_ r: OrganiserRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(r.status == "ok" ? Theme.accent : (r.status == nil ? Theme.olive : Theme.signal)).frame(width: 8, height: 8)
                MonoLabel("Latest run" + (r.run.flatMap(ISO8601DateFormatter.flexible).map { " · " + $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "") + (r.status.map { " · " + $0 } ?? ""))
            }
            if let s = r.summary { Text(s).font(Theme.sans(17)).fixedSize(horizontal: false, vertical: true) }
        }
        let open = store.review?.open.count ?? 0
        if open > 0 {
            Button { store.tab = .review } label: {
                Text("\(open) waiting on Review  →").font(Theme.mono(12)).foregroundStyle(Theme.accent)
            }.buttonStyle(.plain)
        }
        if let filed = r.filed, !filed.isEmpty {
            section("Filed", filed.map { ($0.name ?? "", $0.to ?? "", $0.link) })
        }
        if let junk = r.junk, !junk.isEmpty {
            section("Moved to _To Delete", junk.map { ($0.name ?? "", $0.why ?? "", nil) })
        }
        if let notes = r.notes, !notes.isEmpty {
            section("Notes", notes.map { ($0, "", nil) })
        }
    }

    private func section(_ title: String, _ rows: [(String, String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MonoLabel(title).padding(.bottom, 6)
            Rectangle().fill(Theme.line1).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    if let link = row.2, let u = URL(string: link) {
                        Link(row.0, destination: u).font(Theme.sans(14)).foregroundStyle(Theme.paper)
                    } else {
                        Text(row.0).font(Theme.sans(14))
                    }
                    if !row.1.isEmpty { Text(row.1).font(Theme.sans(12)).foregroundStyle(Theme.muted) }
                }
                .padding(.vertical, 8)
                Rectangle().fill(Theme.line1).frame(height: 1)
            }
        }
    }
}
