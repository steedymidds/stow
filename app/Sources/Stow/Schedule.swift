import Foundation

/// Runs Organise now every morning on this Mac through a LaunchAgent, so images and
/// cloud-only files are read natively (the cloud daily run can't look at them).
enum MorningRun {
    static let label = "io.github.steedymidds.stow.organise"
    static var plist: URL { StowPaths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static let hour = 6, minute = 15

    static var isOn: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ on: Bool) throws {
        let uid = getuid()
        _ = launchctl(["bootout", "gui/\(uid)/\(label)"])
        if !on {
            try? FileManager.default.removeItem(at: plist)
            return
        }
        let exe = Bundle.main.executableURL?.path ?? StowPaths.home.appendingPathComponent("Applications/Stow.app/Contents/MacOS/Stow").path
        let logs = StowPaths.stowHome.appendingPathComponent("log/morning-run.log").path
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--organise"],
            "StartCalendarInterval": ["Hour": hour, "Minute": minute],
            "StandardOutPath": logs,
            "StandardErrorPath": logs,
            "ProcessType": "Background",
        ]
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        let r = launchctl(["bootstrap", "gui/\(uid)", plist.path])
        if r != 0 { throw EngineError.tool("launchctl couldn't load the morning run (\(r)).") }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
