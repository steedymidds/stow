import Foundation
import AppKit

/// Runs Claude Code (`claude -p`) on this Mac, on the user's own Claude plan.
enum ClaudeCLI {
    static var path: String? {
        let home = StowPaths.home.path
        for p in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = StowPaths.home.path
        env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        env["HOME"] = home
        return env
    }

    /// True when Claude Code is signed in. Runs `claude auth status` (no network call to a model).
    static func signedIn() async -> Bool? {
        guard let path else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = ["auth", "status"]
                p.environment = environment
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                cont.resume(returning: obj?["loggedIn"] as? Bool ?? false)
            }
        }
    }

    /// Opens Terminal with `claude auth login`; the user finishes the sign-in themselves.
    static func openLogin() {
        let dir = StowPaths.stowHome.appendingPathComponent("state")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("claude-sign-in.command")
        let body = "#!/bin/zsh\nexport PATH=\"$HOME/.local/bin:/opt/homebrew/bin:$PATH\"\necho 'Signing Claude Code in for Stow…'\nclaude auth login\necho\necho 'Done. You can close this window and go back to Stow.'\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}

@MainActor
final class ClaudeRun: ObservableObject, Identifiable {
    enum Phase: Equatable { case running, finished, failed(String), stopped }
    let id = UUID()
    let title: String
    let started = Date()
    @Published var phase: Phase = .running
    @Published var lines: [String] = []
    @Published var text = ""
    @Published var result: String?
    @Published var cost: Double?
    private var process: Process?
    var onFinish: (() -> Void)?

    init(title: String) { self.title = title }

    var isRunning: Bool { phase == .running }

    func start(prompt: String, model: String, tools: [String], addDirs: [URL], cwd: URL) {
        guard let cli = ClaudeCLI.path else { phase = .failed("Claude Code isn't installed on this Mac."); return }
        var args = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose",
                    "--allowedTools", tools.joined(separator: ","), "--permission-mode", "acceptEdits"]
        for d in addDirs { args += ["--add-dir", d.path] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        p.environment = ClaudeCLI.environment
        p.currentDirectoryURL = cwd
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var errText = ""
        err.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if !s.isEmpty { DispatchQueue.main.async { errText += s } }
        }
        let reader = LineReader(out.fileHandleForReading)
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                err.fileHandleForReading.readabilityHandler = nil
                if self.phase == .running {
                    if proc.terminationStatus == 0 || self.result != nil { self.phase = .finished }
                    else { self.phase = .failed(errText.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Claude Code stopped (\(proc.terminationStatus)).") }
                }
                self.onFinish?()
            }
        }
        do { try p.run() } catch { phase = .failed(error.localizedDescription); return }
        process = p
        DispatchQueue.global(qos: .userInitiated).async {
            while let line = reader.readLine() {
                guard let data = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                DispatchQueue.main.async { self.handle(obj) }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        phase = .stopped
        process?.terminate()
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "assistant":
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        text += (text.isEmpty ? "" : "\n\n") + t
                        for l in t.split(separator: "\n") where !l.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(String(l)) }
                    }
                case "tool_use":
                    lines.append("· " + Self.describe(block))
                default: break
                }
            }
        case "result":
            result = obj["result"] as? String
            cost = obj["total_cost_usd"] as? Double
            if (obj["is_error"] as? Bool) == true {
                phase = .failed(result ?? "Claude Code reported an error.")
            } else if phase == .running {
                phase = .finished
            }
        default: break
        }
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
    }

    private static func describe(_ block: [String: Any]) -> String {
        let name = block["name"] as? String ?? "tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let home = StowPaths.home.path
        func short(_ s: String) -> String {
            let t = s.replacingOccurrences(of: home, with: "~").replacingOccurrences(of: "\n", with: " ")
            return t.count > 140 ? String(t.prefix(140)) + "…" : t
        }
        if let d = input["description"] as? String, !d.isEmpty { return name + " · " + short(d) }
        if let c = input["command"] as? String { return name + " · " + short(c) }
        if let f = input["file_path"] as? String { return name + " · " + short(f) }
        if let p = input["pattern"] as? String { return name + " · " + short(p) }
        return name
    }

    /// The `RESULT:` line the organiser ends with, if any.
    var resultLine: String? {
        let all = (result ?? text)
        return all.split(separator: "\n").last(where: { $0.hasPrefix("RESULT:") }).map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
    }
}

extension Store {
    // MARK: Organise now / Tidy a folder
    func organise(folder: URL? = nil) async {
        if organiseRun?.isRunning == true { tab = .runs; return }
        tab = .runs
        if await ClaudeCLI.signedIn() != true {
            claudeSignedIn = false
            notice = ("Claude Code is signed out on this Mac. Sign in, then try again.", true)
            return
        }
        claudeSignedIn = true
        let reviewBefore = review?.open.count ?? 0
        let runId = UUID().uuidString.prefix(8)
        let lockDir = StowPaths.stowHome.appendingPathComponent("state")
        let lock = lockDir.appendingPathComponent("organise.lock")
        try? FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: lock.path),
           let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < 7200 {
            notice = ("Another organiser run started at \(m.formatted(.dateTime.hour().minute())) and is still going.", true)
            return
        }
        try? "run \(runId) \(ISO8601DateFormatter().string(from: Date())) app".write(to: lock, atomically: true, encoding: .utf8)
        let mode = folder.map { "Tidy folder \($0.path)" } ?? "Organise now"
        let run = ClaudeRun(title: folder.map { "Tidy " + $0.lastPathComponent } ?? "Organise now")
        organiseRun = run
        run.onFinish = { [weak self] in
            try? FileManager.default.removeItem(at: lock)
            guard let self else { return }
            self.load()
            switch run.phase {
            case .finished:
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let added = (self.review?.open.count ?? 0) - reviewBefore
                    self.toast(run.title + " finished", .success, detail: run.resultLine,
                               action: added > 0 ? ("Open Review", { self.tab = .review }) : nil)
                }
            case .failed(let m): self.toast(run.title + " stopped", .error, detail: m)
            case .stopped: self.toast(run.title + " stopped", .info, detail: "Anything already filed stays filed; see the log.")
            case .running: break
            }
        }
        let home = StowPaths.home
        var dirs = [home.appendingPathComponent("Desktop"), home.appendingPathComponent("Downloads"),
                    home.appendingPathComponent("Documents"), home.appendingPathComponent(".Trash"),
                    home.appendingPathComponent("Library/CloudStorage")]
        dirs += registry.compactMap { $0.rootURL }
        if let folder { dirs.append(folder) }
        toast(run.title + " started", .info, detail: "You can keep working. Progress shows in Runs and in the header.")
        let prompt = """
        Read ORGANISER.md in the current folder and follow it exactly.
        Mode: \(mode)
        Run id: \(runId) (the lock at state/organise.lock is yours).
        Today is \(Date().formatted(.iso8601.year().month().day())).
        """
        run.start(prompt: prompt, model: "sonnet", tools: ["Bash", "Read", "Write", "Edit", "Glob", "Grep"],
                  addDirs: Array(Set(dirs)), cwd: StowPaths.stowHome)
    }

    func chooseAndTidy() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Tidy this folder"
        panel.message = "Stow files what it's sure of and puts the rest in Review."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await organise(folder: url) }
    }

    // MARK: Ask
    func writeAskIndex() {
        let url = StowPaths.stowHome.appendingPathComponent("catalogue-ask.tsv")
        let clean: (String) -> String = { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        var out = "source_id\tsource\tbusiness\tkind\tmonth\tsize\tlink\tpath\tsummary\n"
        for e in entries {
            let r = e.row
            let kind = r.k == "s" ? "set of \(r.n ?? 0) files" : (r.g ?? "file")
            out += [r.d, e.sourceName, e.business, kind, String((r.m ?? "").prefix(7)), Fmt.size(r.b),
                    Links.web(r)?.absoluteString ?? "", r.p, r.s ?? ""].map(clean).joined(separator: "\t") + "\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    func ask(_ question: String) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        askRun?.stop()
        if await ClaudeCLI.signedIn() != true {
            claudeSignedIn = false
            let run = ClaudeRun(title: q); run.phase = .failed("Claude Code is signed out on this Mac. Sign in, then ask again.")
            askRun = run
            return
        }
        claudeSignedIn = true
        writeAskIndex()
        let run = ClaudeRun(title: q)
        askRun = run
        let dirs = registry.filter { $0.enabled != false }.compactMap { $0.rootURL }
        run.start(prompt: "Read ASK.md in the current folder and follow it.\n\nQuestion: " + q,
                  model: "haiku", tools: ["Read", "Grep", "Glob"], addDirs: dirs, cwd: StowPaths.stowHome)
    }

    /// Entries the answer names as `ID:path`.
    func mentioned(in text: String) -> [Entry] {
        guard let re = try? NSRegularExpression(pattern: "`([A-Z][A-Z0-9]{0,7}):([^`]+)`") else { return [] }
        var keys: [String] = []
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            keys.append(ns.substring(with: m.range(at: 1)) + "\u{1}" + ns.substring(with: m.range(at: 2)))
        }
        guard !keys.isEmpty else { return [] }
        var byKey: [String: Entry] = [:]
        let wanted = Set(keys)
        for e in entries where wanted.contains(e.row.d + "\u{1}" + e.row.p) { byKey[e.row.d + "\u{1}" + e.row.p] = e }
        var seen = Set<String>()
        return keys.compactMap { k in
            guard !seen.contains(k), let e = byKey[k] else { return nil }
            seen.insert(k); return e
        }
    }
}
