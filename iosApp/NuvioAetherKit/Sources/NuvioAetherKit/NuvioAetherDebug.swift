import Foundation
@_implementationOnly import AetherEngine

/// Bitmap-subtitle diagnostics: `[AetherPGS]` lines on stdout (Xcode console, `devicectl --console`).
/// Off by default; set `pgsLogging` before the player is created to trace route, cue delivery and the
/// overlay's layers.
public enum NuvioAetherDebug {
    public static var pgsLogging = false

    public static func log(_ line: @autoclosure () -> String) {
        guard pgsLogging else { return }
        print("[AetherPGS] \(line())")
    }

    /// Playback-stall diagnostics: `[AetherStall]` lines on stdout with every engine line, a 5 s
    /// player sampler and app lifecycle events, all wall-clock stamped. Off by default; set it before
    /// the player is created (takes precedence over `pgsLogging`'s engine-line filter).
    public static var stallLogging = false

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public static func stall(_ line: @autoclosure () -> String) {
        guard stallLogging else { return }
        print("[AetherStall] \(stampFormatter.string(from: Date())) \(line())")
    }

    /// Mirrors the engine's subtitle and routing lines (normally OSLog only) onto stdout.
    static func installEngineLogForwarding() {
        if stallLogging {
            guard EngineLog.handler == nil else { return }
            EngineLog.handler = { line in stall("[engine] \(line)") }
            return
        }
        guard pgsLogging, EngineLog.handler == nil else { return }
        let keywords = ["subtitle", "pgs", "bitmap", "drain", "overlay", "route", "cue"]
        EngineLog.handler = { line in
            let lower = line.lowercased()
            guard keywords.contains(where: lower.contains) else { return }
            print("[AetherPGS][engine] \(line)")
        }
    }
}
