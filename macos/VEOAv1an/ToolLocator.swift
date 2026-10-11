//
//  ToolLocator.swift — find veo / av1an / ffprobe / ffmpeg on this Mac
//

import Foundation

enum ToolLocator {
    /// Binaries bundled inside the .app (Contents/Resources/tools/) —
    /// checked first so the app works without any system installs.
    static var bundledToolsDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("tools")
    }

    static let searchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin",
        NSHomeDirectory() + "/.cargo/bin",
        NSHomeDirectory() + "/go/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    /// Resolve a tool name to an absolute path: bundled copy first, then
    /// PATH, then common install dirs.
    static func find(_ name: String) -> String? {
        if let bundled = bundledToolsDir?.appendingPathComponent(name).path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in (envPath.split(separator: ":").map(String.init) + searchDirs) {
            let candidate = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func missing(_ names: [String]) -> [String] {
        names.filter { find($0) == nil }
    }

    /// PATH for child processes: bundled tools + every dir we search +
    /// inherited PATH. GUI apps get a minimal PATH (/usr/bin:/bin:...), so
    /// spawned tools like veo/av1an couldn't find ffprobe/ffmpeg themselves.
    static func childPath() -> String {
        var dirs = bundledToolsDir.map { [$0.path] } ?? []
        dirs += searchDirs
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        dirs += envPath.split(separator: ":").map(String.init)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }
}
