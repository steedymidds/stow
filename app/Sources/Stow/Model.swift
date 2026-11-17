import Foundation
import AppKit

enum StowPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let stowHome = home.appendingPathComponent("Documents/.file-organiser")
    static let review = home.appendingPathComponent("Documents/_Review")
    static let catalogue = stowHome.appendingPathComponent("catalogue.json")
    static let cataloguePrivate = stowHome.appendingPathComponent("catalogue-private.json")
    static let reviewQueue = stowHome.appendingPathComponent("review/review.json")
    static let organiser = stowHome.appendingPathComponent("organiser.json")
    static let sources = stowHome.appendingPathComponent("sources.json")
}

struct Source: Decodable, Identifiable, Hashable {
    let id: String
    let root: String?
    let label: String?
    let kind: String?
    let account: String?
    let business: String?
    let role: String?
    let enabled: Bool?
    let isPrivate: Bool?
    let status: String?
    let entries: Int?
    let files: Int?

    enum CodingKeys: String, CodingKey {
        case id, root, label, kind, account, business, role, enabled, status, entries, files
        case isPrivate = "private"
    }
    var name: String { label ?? id }
    var rootURL: URL? {
        guard let root, !root.isEmpty else { return nil }
        return URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
    }
}

/// One catalogue row, same short keys as catalogue.json.
struct Row: Decodable {
    let k: String?      // "f" file, "s" set (folder bundle)
    let d: String       // source id
    let p: String       // path under the source root
    let n: Int?         // files in a set
    let b: Double?      // bytes
    let m: String?      // modified YYYY-MM-DD
    let i: String?      // Drive id
    let pi: String?     // Drive parent folder id
    let u: String?      // web link
    let s: String?      // summary
    let g: String?      // Google file type
}

struct CatalogueFile: Decodable {
    let built: String?
    let sources: [Source]?
    let detected: [Detected]?
    let rows: [Row]
}

struct SourcesFile: Decodable { let sources: [Source] }

struct Entry: Identifiable {
    let id: Int
    let row: Row
    let name: String
    let nameLower: String
    let hay: String
    let isPrivate: Bool
    let business: String
    let sourceName: String
}

enum Fmt {
    static func size(_ b: Double?) -> String {
        guard let b, b > 0 else { return "" }
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(b))
    }
    static func count(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_GB")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func niceName(_ r: Row) -> String {
        var n = (r.p as NSString).lastPathComponent
        if r.g != nil {
            for ext in [".gdoc", ".gsheet", ".gslides", ".gform", ".gdraw", ".gscript", ".gsite"] where n.hasSuffix(ext) {
                n = String(n.dropLast(ext.count))
            }
        }
        return n
    }
}

enum Links {
    static let docURL: [String: String] = [
        "Google Doc": "https://docs.google.com/document/d/",
        "Google Sheet": "https://docs.google.com/spreadsheets/d/",
        "Google Slides": "https://docs.google.com/presentation/d/",
        "Google Form": "https://docs.google.com/forms/d/",
    ]
    static func web(_ r: Row) -> URL? {
        if let u = r.u { return URL(string: u) }
        if r.k == "s" { return r.i.flatMap { URL(string: "https://drive.google.com/drive/folders/" + $0) } }
        if let i = r.i {
            if let g = r.g, let base = docURL[g] { return URL(string: base + i + "/edit") }
            return URL(string: "https://drive.google.com/file/d/" + i + "/view")
        }
        if let pi = r.pi { return URL(string: "https://drive.google.com/drive/folders/" + pi) }
        return nil
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var sources: [String: Source] = [:]
    @Published var sourceOrder: [Source] = []
    @Published var entries: [Entry] = []
    @Published var built: Date?
    @Published var loadError: String?
    @Published var loading = true
    @Published var review: ReviewQueue?
    @Published var tab: Tab = .find
    @Published var registry: [Source] = []
    @Published var detected: [Detected] = []
    @Published var run: OrganiserRun?
    @Published var logs: [URL] = []
    @Published var busy: [String: String] = [:]
    /// Older call sites set `notice`; it now becomes a toast.
    @Published var notice: (text: String, error: Bool)? {
        didSet { if let n = notice { notice = nil; toast(n.text, n.error ? .error : .success) } }
    }
    @Published var toasts: [Toast] = []
    @Published var progress: [String: Double] = [:]
    @Published var sessionDone: [String] = []
    @Published var undoStack: [String] = []
    var lastMessage = ""
    var lastClick = Date.distantPast
    @Published var organiseRun: ClaudeRun?
    @Published var askRun: ClaudeRun?
    @Published var claudeSignedIn: Bool?
    @Published var rebuilding = false
    @Published var rebuildLog = ""
    private var stamps: [String: Date] = [:]

    func localURL(_ r: Row) -> URL? {
        sources[r.d]?.rootURL?.appendingPathComponent(r.p)
    }

    func load() {
        loading = true
        Task.detached(priority: .userInitiated) {
            let result = Store.read()
            await MainActor.run {
                self.apply(result)
            }
        }
    }

    struct Loaded {
        var registry: [Source] = []
        var detected: [Detected] = []
        var run: OrganiserRun?
        var logs: [URL] = []
        var sources: [Source] = []
        var entries: [Entry] = []
        var built: Date?
        var error: String?
        var review: ReviewQueue?
    }

    nonisolated static func read() -> Loaded {
        var out = Loaded()
        let dec = JSONDecoder()
        var srcMap: [String: Source] = [:]
        var order: [String] = []
        var rows: [(Row, Bool)] = []
        var errors: [String] = []
        for (url, isPrivate) in [(StowPaths.catalogue, false), (StowPaths.cataloguePrivate, true)] {
            do {
                let data = try Data(contentsOf: url)
                let c = try dec.decode(CatalogueFile.self, from: data)
                for s in c.sources ?? [] where srcMap[s.id] == nil { srcMap[s.id] = s; order.append(s.id) }
                rows += c.rows.map { ($0, isPrivate) }
                if !isPrivate, let b = c.built { out.built = ISO8601DateFormatter.flexible(b) }
                if !isPrivate { out.detected = c.detected ?? [] }
            } catch {
                errors.append(url.lastPathComponent + ": " + error.localizedDescription)
            }
        }
        // Rows from the private catalogue may repeat public rows; keep the first.
        var seen = Set<String>()
        var entries: [Entry] = []
        entries.reserveCapacity(rows.count)
        for (r, priv) in rows {
            let key = r.d + "\u{1}" + r.p
            if seen.contains(key) { continue }
            seen.insert(key)
            let src = srcMap[r.d]
            let name = Fmt.niceName(r)
            let business = src?.business ?? ""
            let sname = src?.name ?? r.d
            let hay = [r.p, r.s ?? "", r.g ?? "", sname, business].joined(separator: " ").lowercased()
            entries.append(Entry(id: entries.count, row: r, name: name, nameLower: name.lowercased(), hay: hay,
                                 isPrivate: priv || (src?.isPrivate ?? false), business: business, sourceName: sname))
        }
        out.sources = order.compactMap { srcMap[$0] }
        out.entries = entries
        out.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        out.review = try? ReviewQueue.read()
        if let d = try? Data(contentsOf: StowPaths.sources) { out.registry = (try? dec.decode(SourcesFile.self, from: d))?.sources ?? [] }
        if let d = try? Data(contentsOf: StowPaths.organiser) { out.run = try? dec.decode(OrganiserRun.self, from: d) }
        let logDir = StowPaths.stowHome.appendingPathComponent("log")
        out.logs = ((try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent.first?.isNumber == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        return out
    }

    func apply(_ l: Loaded) {
        sourceOrder = l.sources
        sources = Dictionary(uniqueKeysWithValues: l.sources.map { ($0.id, $0) })
        entries = l.entries
        built = l.built
        loadError = l.error
        review = l.review
        registry = l.registry
        detected = l.detected
        run = l.run
        logs = l.logs
        loading = false
        stamps = Store.currentStamps()
    }

    // MARK: refresh when the daily run (or anything else) changes the files
    nonisolated static func currentStamps() -> [String: Date] {
        var out: [String: Date] = [:]
        for u in [StowPaths.catalogue, StowPaths.cataloguePrivate, StowPaths.reviewQueue, StowPaths.organiser, StowPaths.sources] {
            out[u.path] = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return out
    }
    func reloadIfChanged() {
        if loading || !busy.isEmpty || rebuilding { return }
        if Store.currentStamps() != stamps { load() }
    }
    func reloadReview() {
        review = try? ReviewQueue.read()
        stamps = Store.currentStamps()
    }

    var fileIntoSources: [Source] {
        registry.filter { $0.enabled != false && $0.role == "file-into" }
    }
    func sourceName(_ id: String?) -> String {
        guard let id else { return "" }
        return (registry.first { $0.id == id } ?? sources[id])?.name ?? id
    }
    func rootURL(_ id: String) -> URL? {
        (registry.first { $0.id == id } ?? sources[id])?.rootURL
    }

    var businesses: [String] {
        var seen = Set<String>(); var out: [String] = []
        for s in sourceOrder where s.enabled != false {
            if let b = s.business, !b.isEmpty, !seen.contains(b) { seen.insert(b); out.append(b) }
        }
        return out
    }

    func search(_ q: String, business: String?, source: String?) -> [Entry] {
        let tokens = q.lowercased()
            .split(whereSeparator: { " ,/".contains($0) })
            .map(String.init)
            .filter { $0.count > 1 || $0.contains(where: \.isNumber) }
        var scored: [(Int, Entry)] = []
        for e in entries {
            if let business, e.business != business { continue }
            if let source, e.row.d != source { continue }
            var score = 0
            var ok = true
            for t in tokens {
                if !e.hay.contains(t) { ok = false; break }
                score += e.nameLower.contains(t) ? 3 : 1
            }
            if ok { scored.append((score, e)) }
        }
        scored.sort { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            return (a.1.row.m ?? "") > (b.1.row.m ?? "")
        }
        return scored.map(\.1)
    }

    // MARK: actions
    func open(_ e: Entry) {
        if let url = localURL(e.row), FileManager.default.fileExists(atPath: url.path), e.row.g == nil {
            NSWorkspace.shared.open(url)
        } else if let web = Links.web(e.row) {
            NSWorkspace.shared.open(web)
        } else if let url = localURL(e.row) {
            NSWorkspace.shared.open(url)
        }
    }
    func reveal(_ e: Entry) {
        if let url = localURL(e.row), FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let pi = e.row.pi, let u = URL(string: "https://drive.google.com/drive/folders/" + pi) {
            NSWorkspace.shared.open(u)
        }
    }
    func copyPath(_ e: Entry) {
        let path = localURL(e.row)?.path ?? e.row.p
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Haptic.tap()
    }
}

extension ISO8601DateFormatter {
    static func flexible(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        let g = DateFormatter(); g.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            g.dateFormat = fmt
            if let d = g.date(from: s) { return d }
        }
        return nil
    }
}
