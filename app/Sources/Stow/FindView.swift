import SwiftUI

struct FindView: View {
    @EnvironmentObject var store: Store
    @UIState private var query = ""
    @UIState private var business: String? = nil
    @UIState private var source: String? = nil
    @UIState private var results: [Entry] = []
    @UIState private var shown = 80
    @FocusState private var focused: Bool
    @UIState private var asking = false
    @UIState private var question = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(asking ? "Ask about your files" : "Where is it?").font(Theme.sans(44)).tracking(-1.2)
                    Spacer()
                    HStack(spacing: 6) {
                        Chip(title: "Search", on: !asking) { asking = false }
                        Chip(title: "Ask Claude", on: asking) { asking = true }
                    }
                }
                if asking {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("Question, in plain English")
                        HStack(alignment: .bottom, spacing: 16) {
                            TextField("", text: $question, prompt: Text("Where's the latest tenancy agreement?").foregroundColor(Theme.olive))
                                .textFieldStyle(.plain).font(Theme.sans(20)).focused($focused)
                                .padding(.vertical, 8)
                                .overlay(alignment: .bottom) { Rectangle().fill(focused ? Theme.accent : Theme.line3).frame(height: 1) }
                                .onSubmit { if store.askRun?.isRunning != true { Task { await store.ask(question) } } }
                            ThemeButton(title: store.askRun?.isRunning == true ? "Asking…" : "Ask  →", kind: .primary,
                                        working: store.askRun?.isRunning == true) {
                                if store.allowClick() { Task { await store.ask(question) } }
                            }
                        }
                        Text("Claude searches the whole catalogue, private sources included, and can look inside files. It runs on this Mac and can't change anything.")
                            .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    }
                } else {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        MonoLabel("Search names, folders and summaries")
                        TextField("", text: $query, prompt: Text("tenancy agreement").foregroundColor(Theme.olive))
                            .textFieldStyle(.plain)
                            .font(Theme.sans(20))
                            .focused($focused)
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(focused ? Theme.accent : Theme.line3).frame(height: 1)
                            }
                    }
                    Picker("", selection: $source) {
                        Text("All sources").tag(String?.none)
                        ForEach(store.sourceOrder.filter { $0.enabled != false }) { s in
                            Text(s.name + (s.isPrivate == true ? " · private" : "")).tag(String?.some(s.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                }
                if !asking {
                HStack(spacing: 8) {
                    Chip(title: "All", on: business == nil) { business = nil }
                    ForEach(store.businesses, id: \.self) { b in
                        Chip(title: b, on: business == b) { business = b }
                    }
                    Spacer()
                    MonoLabel(countText)
                }
                }
            }
            .padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 16)

            Rectangle().fill(Theme.line2).frame(height: 1).padding(.horizontal, 30)

            if asking {
                ScrollView {
                    if let run = store.askRun {
                        AnswerView(run: run).padding(.horizontal, 30).padding(.vertical, 20)
                    } else {
                        Text("Try: “Which invoices did Anthropic send in September?” or “Where are the Zodiac 2026 campaign files?”")
                            .font(Theme.sans(15)).foregroundStyle(Theme.warmGrey).padding(30)
                    }
                }
            } else if let err = store.loadError, store.entries.isEmpty {
                Text("Couldn't read the catalogue. \(err)")
                    .font(Theme.sans(15)).foregroundStyle(Theme.signal).padding(30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results.prefix(shown)) { e in
                            ResultRow(entry: e)
                            Rectangle().fill(Theme.line2).frame(height: 1)
                        }
                        if results.count > shown {
                            ThemeButton(title: "Show more", kind: .secondary, small: true) { shown += 150 }
                                .padding(.vertical, 16)
                        }
                        if results.isEmpty && !store.loading {
                            Text("Nothing matches. Try fewer words.")
                                .font(Theme.sans(15)).foregroundStyle(Theme.warmGrey).padding(.vertical, 24)
                        }
                    }
                    .padding(.horizontal, 30)
                }
            }
        }
        .task(id: Key(q: query, b: business, s: source, n: store.entries.count)) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            results = store.search(query, business: business, source: source)
            shown = 80
        }
        .onAppear { focused = true }
    }

    private struct Key: Equatable { let q: String; let b: String?; let s: String?; let n: Int }

    private var countText: String {
        let n = Fmt.count(results.count)
        if query.isEmpty && business == nil && source == nil { return n + " entries" }
        return n + (results.count == 1 ? " match" : " matches")
    }
}

struct ResultRow: View {
    @EnvironmentObject var store: Store
    let entry: Entry
    @UIState private var hover = false
    @UIState private var copied = false

    var body: some View {
        let r = entry.row
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(entry.name).font(Theme.sans(16))
                    .foregroundStyle(hover ? Theme.accent : Theme.paper)
                    .lineLimit(2)
                if entry.isPrivate {
                    Text("PRIVATE").font(Theme.mono(9)).tracking(0.9).foregroundStyle(Theme.lavender)
                }
                Spacer(minLength: 8)
                MonoLabel(meta)
            }
            Text(entry.sourceName + " / " + r.p)
                .font(Theme.sans(13)).foregroundStyle(Theme.warmGrey)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
            if let s = r.s, !s.isEmpty {
                Text(s).font(Theme.sans(13)).foregroundStyle(Theme.muted).lineLimit(3)
            }
            if hover {
                HStack(spacing: 8) {
                    ThemeButton(title: "Open", kind: .secondary, small: true) { store.open(entry) }
                    ThemeButton(title: "Show in Finder", kind: .ghost, small: true) { store.reveal(entry) }
                    ThemeButton(title: copied ? "Copied" : "Copy path", kind: .ghost, small: true) {
                        store.copyPath(entry); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Theme.surface : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { store.open(entry) }
        .contextMenu {
            Button("Open") { store.open(entry) }
            Button("Show in Finder") { store.reveal(entry) }
            Button("Copy path") { store.copyPath(entry) }
        }
    }

    private var meta: String {
        let r = entry.row
        let what: String = r.k == "s" ? Fmt.count(r.n ?? 0) + " files" : (r.g ?? Fmt.size(r.b))
        return [entry.business, String((r.m ?? "").prefix(7)), what].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
