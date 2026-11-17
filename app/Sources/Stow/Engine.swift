import Foundation

enum EngineError: LocalizedError {
    case notStarted(String)
    case tool(String)
    case broken(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notStarted(let s): return "The Stow engine didn't start: \(s)"
        case .tool(let s): return s
        case .broken(let s): return "The Stow engine stopped: \(s)"
        case .timeout: return "The Stow engine didn't answer in time."
        }
    }
}

/// Reads newline-delimited messages from a pipe (blocking).
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    init(_ handle: FileHandle) { self.handle = handle }
    func readLine() -> String? {
        while true {
            if let i = buffer.firstIndex(of: 0x0a) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}

/// Talks to the Stow MCP server (see STOW_ENGINE) over stdio, the same engine Claude uses,
/// so filing keeps its verified copy, then the original goes to the source's trash.
final class Engine: @unchecked Sendable {
    static let shared = Engine()
    private let queue = DispatchQueue(label: "io.github.steedymidds.stow.engine")
    private var process: Process?
    private var input: FileHandle?
    private var reader: LineReader?
    private var nextId = 1

    private func launchConfig() -> (String, [String], [String: String]) {
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        var cmd = nodeCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/node"
        let enginePath = ProcessInfo.processInfo.environment["STOW_ENGINE"]
            ?? StowPaths.home.appendingPathComponent(".stow/engine/src/index.js").path
        var args = [enginePath]
        var env: [String: String] = [:]
        let cfg = StowPaths.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        if let data = try? Data(contentsOf: cfg),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = root["mcpServers"] as? [String: Any],
           let stow = servers["stow"] as? [String: Any] {
            if let c = stow["command"] as? String { cmd = c }
            if let a = stow["args"] as? [String] { args = a }
            if let e = stow["env"] as? [String: String] { env = e }
        }
        return (cmd, args, env)
    }

    private func ensureStarted() throws {
        if let p = process, p.isRunning { return }
        let (cmd, args, extra) = launchConfig()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        extra.forEach { env[$0.key] = $0.value }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        do { try p.run() } catch { throw EngineError.notStarted(error.localizedDescription) }
        process = p
        input = inPipe.fileHandleForWriting
        reader = LineReader(outPipe.fileHandleForReading)
        _ = try request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Stow for Mac", "version": "1.0"],
        ])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func send(_ obj: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0a)
        guard let input else { throw EngineError.broken("no input") }
        try input.write(contentsOf: data)
    }

    private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = nextId; nextId += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            guard let line = reader?.readLine() else { throw EngineError.broken("it closed its output") }
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let rid = obj["id"] as? Int, rid == id, obj["method"] == nil {
                if let err = obj["error"] as? [String: Any] {
                    throw EngineError.tool(err["message"] as? String ?? "error")
                }
                return obj["result"] as? [String: Any] ?? [:]
            }
            if let m = obj["method"] as? String, let rid = obj["id"], m == "ping" {
                try send(["jsonrpc": "2.0", "id": rid, "result": [String: Any]()])
            }
        }
    }

    /// Calls a Stow tool and returns its JSON payload (or text).
    func call(_ tool: String, _ args: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            queue.async {
                do {
                    try self.ensureStarted()
                    let res = try self.request("tools/call", ["name": tool, "arguments": args])
                    let text = ((res["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                    if (res["isError"] as? Bool) == true {
                        cont.resume(throwing: EngineError.tool(text.isEmpty ? "failed" : text))
                        return
                    }
                    let parsed: Any = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? text
                    cont.resume(returning: parsed)
                } catch {
                    if case EngineError.tool = error {} else { self.stop() }
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        input = nil
        reader = nil
    }
}
