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
}
