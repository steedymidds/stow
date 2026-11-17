import SwiftUI
import AppKit
import ServiceManagement

@main
struct StowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Stow", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 560)
                .preferredColorScheme(.dark)
                .onAppear {
                    if store.entries.isEmpty { store.load() }
                    Task { store.claudeSignedIn = await ClaudeCLI.signedIn() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reload") { store.load(); store.toast("Reloaded", .info) }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                    else { Task { await store.undoLast() } }
                }
                .keyboardShortcut("z")
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Find") { store.tab = .find }.keyboardShortcut("1")
                Button("Review") { store.tab = .review }.keyboardShortcut("2")
                Button("Runs") { store.tab = .runs }.keyboardShortcut("3")
                Button("Sources") { store.tab = .sources }.keyboardShortcut("4")
            }
            CommandMenu("Stow") {
                Button("Organise now") { Task { await store.organise() } }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Tidy a folder…") { store.chooseAndTidy() }
                Button("Rebuild catalogue") { store.rebuildCatalogue() }
                Button("Sign Claude Code in…") { ClaudeCLI.openLogin() }
            }
        }

        MenuBarExtra {
            MenuContent().environmentObject(store)
        } label: {
            let n = store.review?.open.count ?? 0
            if store.activityText != nil {
                Image(systemName: "arrow.triangle.2.circlepath")
            } else {
                Image(systemName: n > 0 ? "tray.full" : "tray")
            }
            if n > 0 { Text("\(n)") }
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @UIState private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let n = store.review?.open.count ?? 0
        if let a = store.activityText {
            Button("Working: " + a) { show(store.activityTab) }
            Divider()
        }
        Button("Open Stow") { show(.find) }
        Button(n > 0 ? "Review · \(n) waiting" : "Review · nothing waiting") { show(.review) }
        Button("Runs") { show(.runs) }
        Divider()
        Button(store.organiseRun?.isRunning == true ? "Organising…" : "Organise now") { show(.runs); Task { await store.organise() } }
            .disabled(store.organiseRun?.isRunning == true)
        Button("Tidy a folder…") { show(.runs); store.chooseAndTidy() }
        Button("Ask Claude…") { show(.find) }
        Divider()
        Button("Reload") { store.load(); store.toast("Reloaded", .info) }
        Toggle("Open at login", isOn: Binding(get: { atLogin }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                store.notice = ("Couldn't change Open at login: \(error.localizedDescription)", true)
            }
            atLogin = SMAppService.mainApp.status == .enabled
            store.toast(atLogin ? "Stow opens at login" : "Stow won't open at login", .info)
        }))
        Divider()
        Button("Quit Stow") { NSApp.terminate(nil) }.keyboardShortcut("q")
            .onAppear { if store.entries.isEmpty && !store.loading { store.load() } }
    }

    private func show(_ t: Tab) {
        store.tab = t
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let hooks = ["--selftest", "--engine-test", "--act", "--save-source", "--ask-index", "--rebuild", "--ask", "--tidy", "--organise", "--morning", "--undo"]
        if args.contains(where: { hooks.contains($0) }) {
            NSApp.setActivationPolicy(.prohibited)
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
        }
        if let i = args.firstIndex(of: "--selftest") {
            selftest(args.count > i + 1 ? args[i + 1] : "")
        }
        if let i = args.firstIndex(of: "--act"), args.count > i + 2 {
            actTest(args[i + 1], args[i + 2])
        }
        if let i = args.firstIndex(of: "--save-source"), args.count > i + 1 {
            MainActor.assumeIsolated {
                let s = Store(); s.apply(Store.read())
                guard let src = s.registry.first(where: { $0.id == args[i + 1] }) else { print("no source"); exit(1) }
                do { try SourcesIO.save(SourceDraft(src, exclude: SourcesIO.excludes(src.id))); print("saved", src.id) }
                catch { print("save error", error.localizedDescription) }
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--ask"), args.count > i + 1 {
            MainActor.assumeIsolated {
                let s = Store(); s.apply(Store.read())
                Task { @MainActor in
                    await s.ask(args[i + 1])
                    guard let run = s.askRun else { exit(1) }
                    while run.isRunning { try? await Task.sleep(nanoseconds: 300_000_000) }
                    print("ASK PHASE", run.phase)
                    print(run.result ?? run.text)
                    print("MENTIONED", s.mentioned(in: run.result ?? run.text).map { $0.row.d + ":" + $0.row.p })
                    exit(0)
                }
            }
        }
        if let i = args.firstIndex(of: "--undo"), args.count > i + 1 {
            MainActor.assumeIsolated {
                let s = Store(); s.apply(Store.read())
                Task { @MainActor in
                    await s.undo(args[i + 1])
                    print("undo:", s.review?.items.first { $0.id == args[i + 1] }?.status ?? "?", "|", s.lastMessage)
                    exit(0)
                }
            }
        }
        if let i = args.firstIndex(of: "--morning"), args.count > i + 1 {
            do { try MorningRun.set(args[i + 1] == "on"); print("morning run", MorningRun.isOn ? "on" : "off") }
            catch { print("morning error", error.localizedDescription) }
            exit(0)
        }
        if args.contains("--organise") {
            MainActor.assumeIsolated {
                let s = Store(); s.apply(Store.read())
                Task { @MainActor in
                    await s.organise()
                    guard let run = s.organiseRun else { print("ORGANISE not started:", s.lastMessage); exit(1) }
                    var shown = 0
                    while run.isRunning {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        while shown < run.lines.count { print(run.lines[shown]); fflush(stdout); shown += 1 }
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    print(Date().formatted(.iso8601), "ORGANISE PHASE", run.phase, "|", run.resultLine ?? "")
                    exit(0)
                }
            }
        }
        if let i = args.firstIndex(of: "--tidy"), args.count > i + 1 {
            MainActor.assumeIsolated {
                let s = Store(); s.apply(Store.read())
                Task { @MainActor in
                    await s.organise(folder: URL(fileURLWithPath: args[i + 1]))
                    guard let run = s.organiseRun else { print("TIDY not started:", s.lastMessage); exit(1) }
                    var shown = 0
                    while run.isRunning {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        while shown < run.lines.count { print(run.lines[shown]); shown += 1 }
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    print("TIDY PHASE", run.phase, "|", run.resultLine ?? "")
                    exit(0)
                }
            }
        }
        if args.contains("--ask-index") {
            MainActor.assumeIsolated {
                let s = Store(); s.apply(Store.read()); s.writeAskIndex(); print("ask index written", s.entries.count)
            }
            exit(0)
        }
        if args.contains("--rebuild") {
            MainActor.assumeIsolated {
                let s = Store(); s.apply(Store.read()); s.rebuildCatalogue()
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated { if !s.rebuilding { print(s.rebuildLog); exit(0) } }
                }
            }
        }
        if let i = args.firstIndex(of: "--engine-test") {
            engineTest(args.count > i + 1 ? args[i + 1] : "")
        }
    }

    /// `Stow --selftest "query"` loads everything, prints counts and the top matches, then quits.
    private func selftest(_ q: String) {
        MainActor.assumeIsolated {
            let s = Store()
            s.apply(Store.read())
            print("sources", s.sourceOrder.count, "registry", s.registry.count, "entries", s.entries.count,
                  "private", s.entries.filter(\.isPrivate).count, "review open", s.review?.open.count ?? -1,
                  "logs", s.logs.count, "run", s.run?.status ?? "none", "error", s.loadError ?? "none")
            for e in s.search(q, business: nil, source: nil).prefix(5) {
                print("  ", e.sourceName, "/", e.row.p)
            }
        }
        exit(0)
    }

    /// `Stow --act <id> <suggest|bin>` runs a Review action exactly as the button does, then quits.
    private func actTest(_ id: String, _ how: String) {
        Task { @MainActor in
            let s = Store()
            s.apply(Store.read())
            guard let item = s.review?.items.first(where: { $0.id == id }) else { print("act: no item", id); exit(1) }
            if how == "bin" { await s.act(item, .bin) }
            else if let src = item.suggest?.source, let dir = item.suggest?.dir { await s.act(item, .file(source: src, dir: dir)) }
            else { await s.act(item, .bin) }
            let after = s.review?.items.first(where: { $0.id == id })
            print("act:", after?.status ?? "?", "|", s.lastMessage)
            exit(0)
        }
    }

    /// `Stow --engine-test "path"` asks the Stow engine to stat a REV path, then quits.
    private func engineTest(_ p: String) {
        Task {
            do {
                let r = try await Engine.shared.call("stow_stat", ["source": "REV", "path": p])
                print("engine ok:", r)
            } catch {
                print("engine error:", error.localizedDescription)
            }
            exit(0)
        }
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case find = "Find", review = "Review", runs = "Runs", sources = "Sources"
    var id: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    private let tick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line1).frame(height: 1)
            Group {
                switch store.tab {
                case .find: FindView()
                case .review: ReviewView()
                case .runs: RunsView()
                case .sources: SourcesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.void)
        .foregroundStyle(Theme.paper)
        .overlay(alignment: .bottomTrailing) { ToastStack() }
        .onReceive(tick) { _ in store.reloadIfChanged() }
        .onAppear {
            // Warm the Stow engine so the first click doesn't wait for it to start.
            Task.detached(priority: .utility) { _ = try? await Engine.shared.call("stow_sources", [:]) }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            HStack(spacing: 0) {
                Text("stow").font(Theme.sans(22, .heavy))
                Text(".").font(Theme.sans(22, .heavy)).foregroundStyle(Theme.accent)
            }
            .padding(.leading, 30) // same left edge as the headings and the table rule
            Spacer()
            ActivityPill()
                .animation(.easeOut(duration: 0.2), value: store.activityText == nil)
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { t in
                    Button { store.tab = t } label: {
                        HStack(spacing: 6) {
                            Text(t.rawValue.uppercased()).font(Theme.mono(11)).tracking(0.9)
                            if t == .review, let n = store.review?.open.count, n > 0 {
                                Text("\(n)").font(Theme.mono(10))
                                    .contentTransition(.numericText())
                                    .foregroundStyle(Theme.void)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                    .background(Capsule().fill(Theme.accent))
                            }
                        }
                        .padding(.horizontal, 12).frame(height: 30)
                        .foregroundStyle(store.tab == t ? Theme.paper : Theme.warmGrey)
                        .overlay(Capsule().stroke(store.tab == t ? Theme.line3 : .clear, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            MonoLabel(store.loading ? "Loading" : builtText)
                .padding(.trailing, 30)
        }
        .frame(height: 52)
    }

    private var builtText: String {
        guard let d = store.built else { return "Catalogue" }
        return "Updated " + d.formatted(.dateTime.day().month(.abbreviated))
    }
}
