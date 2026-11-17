import Foundation
import AppKit
import CryptoKit
import SwiftUI

enum ReviewAction { case file(source: String, dir: String), bin }

extension Store {
    /// Called straight from a button: shows the working state at once, then runs.
    func start(_ item: ReviewItem, _ action: ReviewAction) {
        guard busy[item.id] == nil, allowClick() else { return }
        Haptic.tap()
        withAnimation(.easeOut(duration: 0.15)) {
            busy[item.id] = { if case .bin = action { return "Binning" } else { return "Filing" } }()
            progress[item.id] = 0
        }
        Task { await act(item, action) }
    }

    func act(_ item: ReviewItem, _ action: ReviewAction) async {
        let total = item.files.count
        var moved = Set<String>()
        var failed: [ReviewFailure] = []
        var undo: [UndoStep] = []
        var stopped: String?
        var alreadyFiled = 0
        if busy[item.id] == nil { busy[item.id] = "Starting" }
        for (k, f) in item.files.enumerated() {
            let name = (f.p as NSString).lastPathComponent
            let src = StowPaths.review.appendingPathComponent(f.p)
            withAnimation(.linear(duration: 0.15)) { progress[item.id] = Double(k) / Double(max(total, 1)) }
            do {
                switch action {
                case .bin:
                    busy[item.id] = "Binning \(k + 1) of \(total) · \(name)"
                    if !FileManager.default.fileExists(atPath: src.path) { moved.insert(f.p); continue }
                    let r = try await Engine.shared.call("stow_trash", ["source": "REV", "path": f.p])
                    if let to = (r as? [String: Any])?["to"] as? String { undo.append(UndoStep(kind: "untrash", p: f.p, from: to)) }
                case .file(let source, let dir):
                    busy[item.id] = "Filing \(k + 1) of \(total) · \(name)"
                    let target = ReviewQueue.target(f.p, dir: dir)
                    let dst = rootURL(source)?.appendingPathComponent(target)
                    if !FileManager.default.fileExists(atPath: src.path) {
                        if let dst, FileManager.default.fileExists(atPath: dst.path) { moved.insert(f.p); continue }
                        throw EngineError.tool("It's no longer in _Review.")
                    }
                    do {
                        _ = try await Engine.shared.call("stow_move", [
                            "from_source": "REV", "from_path": f.p, "to_source": source, "to_path": target,
                        ])
                        undo.append(UndoStep(kind: "unmove", p: f.p, source: source, path: target))
                    } catch EngineError.tool(let msg) where msg.contains("already exists") {
                        guard let dst else { throw EngineError.tool(msg) }
                        let a = Store.md5(src)
                        if a != nil && a == Store.md5(dst) {
                            busy[item.id] = "Already filed · binning the copy of \(name)"
                            let r = try await Engine.shared.call("stow_trash", ["source": "REV", "path": f.p])
                            if let to = (r as? [String: Any])?["to"] as? String { undo.append(UndoStep(kind: "untrash", p: f.p, from: to)) }
                            alreadyFiled += 1
                        } else {
                            let alt = Store.numbered(target, root: rootURL(source))
                            _ = try await Engine.shared.call("stow_move", [
                                "from_source": "REV", "from_path": f.p, "to_source": source, "to_path": alt,
                            ])
                            undo.append(UndoStep(kind: "unmove", p: f.p, source: source, path: alt))
                        }
                    }
                }
                moved.insert(f.p)
            } catch EngineError.tool(let msg) {
                failed.append(ReviewFailure(p: f.p, err: String(msg.prefix(180))))
            } catch {
                stopped = error.localizedDescription
                break
            }
        }
        withAnimation(.linear(duration: 0.15)) { progress[item.id] = 1 }
        var result = ReviewResult(at: ISO8601DateFormatter().string(from: Date()), ok: moved.count, failed: failed)
        result.undo = undo
        let what: String
        switch action {
        case .bin: result.action = "bin"; what = "Binned"
        case .file(let source, let dir): result.action = "file"; result.source = source; result.dir = dir
            what = "Filed to \(sourceName(source)) / \(dir)"
        }
        let remaining = item.files.filter { !moved.contains($0.p) }
        let finished = !moved.isEmpty && remaining.isEmpty
        do {
            try ReviewQueue.update(item.id) { d in
                if moved.isEmpty {
                    d["last"] = ReviewQueue.encode(result)
                } else if remaining.isEmpty {
                    d["status"] = { if case .bin = action { return "binned" } else { return "filed" } }()
                    d["result"] = ReviewQueue.encode(result)
                } else {
                    d["files"] = ReviewQueue.encode(remaining)
                    d["bytes"] = remaining.reduce(0) { $0 + ($1.b ?? 0) }
                    d["last"] = ReviewQueue.encode(result)
                }
            }
        } catch {
            toast("Files moved, but the review list couldn't be saved.", .error, detail: error.localizedDescription)
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            busy[item.id] = nil
            progress[item.id] = nil
            if finished {
                if !sessionDone.contains(item.id) { sessionDone.append(item.id) }
                undoStack.append(item.id)
            }
            reloadReview()
        }
        let id = item.id
        if let stopped {
            toast("\(moved.count) of \(total) done, then Stow stopped.", .error, detail: stopped)
        } else if !failed.isEmpty {
            toast("\(item.title): \(moved.count) of \(total) done.", .error,
                  detail: "\(failed.count) couldn't move and stay in To do. \(failed.first!.err)")
        } else {
            let extra = alreadyFiled > 0 ? " \(alreadyFiled) were already there, so their copies went to the Bin." : ""
            toast("\(item.title)", .success, detail: what + "." + extra,
                  action: ("Undo", { [weak self] in Task { await self?.undo(id) } }),
                  second: whereButton(action))
        }
    }

    private func whereButton(_ action: ReviewAction) -> (String, () -> Void)? {
        switch action {
        case .file(let source, let dir):
            guard let url = rootURL(source)?.appendingPathComponent(dir) else { return nil }
            return ("Show in Finder", { NSWorkspace.shared.open(url) })
        case .bin:
            let url = StowPaths.review.appendingPathComponent("_To Delete")
            return ("Show Bin folder", { NSWorkspace.shared.open(url) })
        }
    }

    // MARK: Undo
    func undoLast() async {
        guard let id = undoStack.popLast() else { toast("Nothing to undo.", .info); return }
        await undo(id)
    }

    func undo(_ id: String) async {
        reloadReview()
        guard let item = review?.items.first(where: { $0.id == id }), busy[id] == nil else { return }
        if item.status == "kept" {
            setStatus(item, "open")
            undoStack.removeAll { $0 == id }
            toast("\(item.title) is back in To do.", .info)
            return
        }
        guard item.status != "open" else { return }
        let steps = item.result?.undo ?? []
        if steps.isEmpty {
            toast("Stow can't undo this one automatically.", .error,
                  detail: "It was done before undo existed. Look in _Review / _To Delete or in the folder it was filed to.")
            return
        }
        withAnimation { busy[id] = "Undoing"; progress[id] = 0 }
        var back = 0
        var problems: [String] = []
        for (k, st) in steps.enumerated() {
            progress[id] = Double(k) / Double(steps.count)
            busy[id] = "Putting back \(k + 1) of \(steps.count)"
            let dest = StowPaths.review.appendingPathComponent(st.p)
            if FileManager.default.fileExists(atPath: dest.path) { back += 1; continue }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch st.kind {
                case "untrash":
                    guard let from = st.from else { throw EngineError.tool("missing trash path") }
                    try FileManager.default.moveItem(at: URL(fileURLWithPath: (from as NSString).expandingTildeInPath), to: dest)
                case "unmove":
                    guard let source = st.source, let path = st.path, let root = rootURL(source) else { throw EngineError.tool("missing destination") }
                    let filed = root.appendingPathComponent(path)
                    try FileManager.default.copyItem(at: filed, to: dest)
                    guard Store.md5(filed) == Store.md5(dest) else {
                        try? FileManager.default.removeItem(at: dest)
                        throw EngineError.tool("the copy back didn't match")
                    }
                    _ = try await Engine.shared.call("stow_trash", ["source": source, "path": path])
                default: break
                }
                back += 1
            } catch {
                problems.append((st.p as NSString).lastPathComponent + ": " + error.localizedDescription)
            }
        }
        try? ReviewQueue.update(id) { d in
            d["status"] = "open"
            d.removeValue(forKey: "result")
            d["last"] = ReviewQueue.encode(ReviewResult(at: ISO8601DateFormatter().string(from: Date()), action: "undo", ok: back))
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            busy[id] = nil; progress[id] = nil
            sessionDone.removeAll { $0 == id }
            undoStack.removeAll { $0 == id }
            reloadReview()
        }
        if problems.isEmpty {
            toast("Undone: \(item.title) is back in To do.", .info)
        } else {
            toast("Undo put back \(back) of \(steps.count).", .error, detail: problems.prefix(3).joined(separator: "\n"))
        }
    }

    func keep(_ item: ReviewItem) {
        guard allowClick() else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            setStatus(item, "kept")
            if !sessionDone.contains(item.id) { sessionDone.append(item.id) }
            undoStack.append(item.id)
        }
        let id = item.id
        toast("\(item.title)", .success, detail: "Kept in _Review. Stow won't ask about it again.",
              action: ("Undo", { [weak self] in Task { await self?.undo(id) } }))
    }

    nonisolated static func md5(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var md5 = Insecure.MD5()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { md5.update(data: chunk) }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "name.ext" → "name (2).ext" (or 3, 4…) for a path that doesn't exist yet under root.
    nonisolated static func numbered(_ target: String, root: URL?) -> String {
        let ns = target as NSString
        let dir = ns.deletingLastPathComponent, ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        for n in 2...99 {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let cand = dir.isEmpty ? name : dir + "/" + name
            if let root, FileManager.default.fileExists(atPath: root.appendingPathComponent(cand).path) { continue }
            return cand
        }
        return target
    }

    func setStatus(_ item: ReviewItem, _ status: String) {
        do {
            try ReviewQueue.update(item.id) { d in
                d["status"] = status
                if status == "kept" {
                    d["result"] = ReviewQueue.encode(ReviewResult(at: ISO8601DateFormatter().string(from: Date()), action: "keep"))
                }
            }
            reloadReview()
        } catch {
            toast("Couldn't save that.", .error, detail: error.localizedDescription)
        }
    }

    func revealInReview(_ f: ReviewFile) {
        let url = StowPaths.review.appendingPathComponent(f.p)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            toast("That file isn't in _Review any more.", .info)
        }
    }
    func quickLook(_ f: ReviewFile) {
        let url = StowPaths.review.appendingPathComponent(f.p)
        if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        else { toast("That file isn't in _Review any more.", .info) }
    }
}
