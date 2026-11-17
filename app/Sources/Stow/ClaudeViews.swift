import SwiftUI

struct SignInPrompt: View {
    @EnvironmentObject var store: Store
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Claude Code is signed out on this Mac, so Organise and Ask can't run.")
                .font(Theme.sans(14)).foregroundStyle(Theme.paper)
            Spacer()
            ThemeButton(title: "Sign in…", kind: .secondary, small: true) {
                ClaudeCLI.openLogin()
                store.toast("Terminal opened", .info, detail: "Finish signing in there, then click Check again.")
            }
            ThemeButton(title: "Check again", kind: .ghost, small: true) {
                Task {
                    store.claudeSignedIn = await ClaudeCLI.signedIn()
                    store.toast(store.claudeSignedIn == true ? "Claude Code is signed in" : "Still signed out", store.claudeSignedIn == true ? .success : .error)
                }
            }
        }
        .padding(12)
        .overlay(Rectangle().stroke(Theme.line2, lineWidth: 1))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.lavender).frame(width: 2) }
    }
}

struct OrganisePanel: View {
    @EnvironmentObject var store: Store
    @UIState private var morning = MorningRun.isOn
    @UIState private var morningError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ThemeButton(title: store.organiseRun?.isRunning == true ? "Organising…" : "Organise now  →", kind: .primary,
                            working: store.organiseRun?.isRunning == true) {
                    if store.allowClick() { Task { await store.organise() } }
                }
                ThemeButton(title: "Tidy a folder…", kind: .secondary) { store.chooseAndTidy() }
                    .disabled(store.organiseRun?.isRunning == true)
            }
            Text("Files Desktop, Downloads and loose Documents now, the same way the daily run does. Anything it isn't sure of goes to Review.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { morning }, set: { on in
                do { try MorningRun.set(on); morningError = nil } catch { morningError = error.localizedDescription }
                morning = MorningRun.isOn
                if morningError == nil {
                    store.toast(morning ? "Morning run on" : "Morning run off", .info,
                                detail: morning ? "Stow organises this Mac every day at 06:15, or when it next wakes." : nil)
                }
            })) {
                Text("Organise every morning at 06:15 on this Mac").font(Theme.sans(14))
            }
            .toggleStyle(.switch).tint(Theme.accent)
            if let morningError { Text(morningError).font(Theme.sans(12)).foregroundStyle(Theme.signal) }
            if store.claudeSignedIn == false { SignInPrompt() }
            if let run = store.organiseRun { RunConsole(run: run) }
        }
    }
}

struct RunConsole: View {
    @EnvironmentObject var store: Store
    @ObservedObject var run: ClaudeRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch run.phase {
                case .running: ProgressView().controlSize(.small)
                case .finished: Circle().fill(Theme.accent).frame(width: 8, height: 8)
                case .failed, .stopped: Circle().fill(Theme.signal).frame(width: 8, height: 8)
                }
                MonoLabel(run.title + " · " + phaseText)
                if run.isRunning {
                    TimelineView(.periodic(from: run.started, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(run.started))
                        Text(String(format: "%d:%02d", s / 60, s % 60)).font(Theme.mono(11)).foregroundStyle(Theme.accent)
                            .monospacedDigit()
                    }
                }
                Spacer()
                if run.isRunning {
                    ThemeButton(title: "Stop", kind: .bin, small: true) { run.stop() }
                } else if run.phase == .finished, (store.review?.open.count ?? 0) > 0 {
                    ThemeButton(title: "Open Review", kind: .secondary, small: true) { store.tab = .review }
                }
            }
            if let r = run.resultLine { Text(r).font(Theme.sans(16)) }
            if case .failed(let m) = run.phase { Text(m).font(Theme.sans(13)).foregroundStyle(Theme.signal) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(run.lines.enumerated()), id: \.offset) { i, l in
                            Text(l).font(Theme.mono(11))
                                .foregroundStyle(l.hasPrefix("·") ? Theme.muted : Theme.warmGrey)
                                .frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                }
                .frame(minHeight: 120, maxHeight: 260)
                .background(Theme.surface)
                .onChange(of: run.lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
        }
    }

    private var phaseText: String {
        switch run.phase {
        case .running: return "running since " + run.started.formatted(.dateTime.hour().minute())
        case .finished: return "finished"
        case .failed: return "stopped with an error"
        case .stopped: return "stopped"
        }
    }
}

struct AnswerView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var run: ClaudeRun

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if run.isRunning { ProgressView().controlSize(.small) }
                MonoLabel(run.isRunning ? "Looking…" : "Answer")
                if run.isRunning {
                    TimelineView(.periodic(from: run.started, by: 1)) { ctx in
                        Text("\(Int(ctx.date.timeIntervalSince(run.started)))s").font(Theme.mono(11)).foregroundStyle(Theme.accent)
                    }
                }
                Spacer()
                if run.isRunning { ThemeButton(title: "Stop", kind: .ghost, small: true) { run.stop() } }
            }
            if case .failed(let m) = run.phase {
                Text(m).font(Theme.sans(14)).foregroundStyle(Theme.signal)
                if store.claudeSignedIn == false { SignInPrompt() }
            }
            let body = run.result ?? run.text
            if !body.isEmpty {
                Text(markdown(body)).font(Theme.sans(16)).foregroundStyle(Theme.paper)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 760, alignment: .leading)
            } else if run.isRunning {
                Text(run.lines.last.map { $0.replacingOccurrences(of: "· ", with: "") } ?? "Starting Claude…")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .transition(.opacity).id(run.lines.count)
            }
            let hits = store.mentioned(in: body)
            if !hits.isEmpty {
                MonoLabel("Open them").padding(.top, 6)
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.line2).frame(height: 1)
                    ForEach(hits) { e in
                        ResultRow(entry: e)
                        Rectangle().fill(Theme.line2).frame(height: 1)
                    }
                }
            }
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
