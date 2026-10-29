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

    /// Mirrors the engine's subtitle and routing lines (normally OSLog only) onto stdout.
    static func installEngineLogForwarding() {
        guard pgsLogging, EngineLog.handler == nil else { return }
        let keywords = ["subtitle", "pgs", "bitmap", "drain", "overlay", "route", "cue"]
        EngineLog.handler = { line in
            let lower = line.lowercased()
            guard keywords.contains(where: lower.contains) else { return }
            print("[AetherPGS][engine] \(line)")
        }
    }
}
