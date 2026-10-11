//
//  ToolLocator.swift — find veo / av1an / ffprobe / ffmpeg on this Mac
//

import Foundation

enum ToolLocator {
    static let searchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin",
        NSHomeDirectory() + "/.cargo/bin",
        NSHomeDirectory() + "/go/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    /// Resolve a tool name to an absolute path: PATH first, then common dirs.
    static func find(_ name: String) -> String? {
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
