import Foundation

struct ReviewFile: Codable, Hashable {
    var p: String
    var b: Double?
}

struct Suggestion: Codable, Hashable {
    var action: String          // "move" | "trash"
    var label: String?
    var source: String?
    var dir: String?
}

struct ReviewFailure: Codable, Hashable {
    var p: String
    var err: String
}

struct UndoStep: Codable, Hashable {
    var kind: String        // "untrash" | "unmove"
    var p: String           // path under _Review to put it back
    var from: String?       // untrash: where Stow trashed it (~ path)
    var source: String?     // unmove: where it was filed
    var path: String?
}

struct ReviewResult: Codable, Hashable {
    var undo: [UndoStep]?
    var at: String?
    var action: String?
    var ok: Int?
    var failed: [ReviewFailure]?
    var source: String?
    var dir: String?
}

struct ReviewItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var when: String?
    var added: String?
    var kind: String?
    var why: String?
    var suggest: Suggestion?
    var files: [ReviewFile]
    var bytes: Double?
    var status: String
    var order: Int?
    var result: ReviewResult?
    var last: ReviewResult?
}

/// ~/Documents/.file-organiser/review/review.json, shared by the app and the daily run.
/// Writes re-read the file first and only touch the one item, keeping any fields the app doesn't know.
struct ReviewQueue {
    var items: [ReviewItem]

    static func read() throws -> ReviewQueue {
        let data = try Data(contentsOf: StowPaths.reviewQueue)
        let raw = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let itemsData = try JSONSerialization.data(withJSONObject: raw["items"] ?? [])
        let items = try JSONDecoder().decode([ReviewItem].self, from: itemsData)
        return ReviewQueue(items: items.sorted { ($0.order ?? 0) < ($1.order ?? 0) })
    }

    var open: [ReviewItem] { items.filter { $0.status == "open" } }
    var kept: [ReviewItem] { items.filter { $0.status == "kept" } }
    var done: [ReviewItem] { items.filter { !["open", "kept"].contains($0.status) } }

    static func update(_ id: String, _ change: (inout [String: Any]) -> Void) throws {
        let url = StowPaths.reviewQueue
        let data = try Data(contentsOf: url)
        guard var root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var items = root["items"] as? [[String: Any]],
              let i = items.firstIndex(where: { ($0["id"] as? String) == id }) else {
            throw EngineError.tool("That item is no longer in the review queue.")
        }
        change(&items[i])
        root["items"] = items
        root["updated"] = ISO8601DateFormatter().string(from: Date())
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    static func encode(_ r: ReviewResult) -> [String: Any] {
        guard let d = try? JSONEncoder().encode(r),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o
    }
    static func encode(_ files: [ReviewFile]) -> [[String: Any]] {
        guard let d = try? JSONEncoder().encode(files),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
        return o
    }

    /// Where a review file lands: the folder plus its path below the dated review folder.
    static func target(_ p: String, dir: String) -> String {
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        let rest = parts.dropFirst().joined(separator: "/")
        let d = dir.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return d.isEmpty ? rest : d + "/" + rest
    }
}

struct OrganiserRun: Decodable {
    struct Filed: Decodable, Hashable { let name: String?; let to: String?; let link: String? }
    struct Junk: Decodable, Hashable { let name: String?; let why: String? }
    let run: String?
    let status: String?
    let summary: String?
    let filed: [Filed]?
    let junk: [Junk]?
    let notes: [String]?
}

struct Detected: Decodable, Hashable {
    let label: String?
    let path: String?
    let stale: Bool?
}
