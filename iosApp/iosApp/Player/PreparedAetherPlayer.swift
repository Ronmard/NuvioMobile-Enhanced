import Foundation
import UIKit

/// The next episode on a second AetherEngine, loaded paused while the current episode plays, so the
/// transition can show it without a fresh load.
///
/// Process-wide because Compose builds a new player surface (and engine router) for every playback:
/// the outgoing router prepares here and the incoming router adopts from here when its first load
/// asks for exactly the prepared stream. Anything else (a different URL, headers or subtitles, mpv
/// as the engine, a prepare that failed) discards it and the load runs as before.
///
/// Picture in Picture: only the mpv path has PiP in this app, and mpv never prepares, so a prepared
/// engine is never adopted out from under a PiP window.
final class PreparedAetherPlayer {
    static let shared = PreparedAetherPlayer()

    struct Arguments: Equatable {
        let videoUrl: String
        let headersJson: String?
        let subtitlesJson: String?
    }

    /// An outgoing engine that kept the audio session for the handoff waits at most this long.
    private static let handoffTimeout: TimeInterval = 10

    private var arguments: Arguments?
    private var bridge: AetherPlayerBridgeImpl?
    private var failed = false
    private var preparedAt = Date()
    private var debugLogging = false
    /// An outgoing AetherEngine left the shared audio session active for the prepared one.
    private var sessionHeldForHandoff = false
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.discard(reason: "memory warning") }
    }

    var hasPrepared: Bool { bridge != nil }

    func prepare(_ arguments: Arguments, startPositionMs: Int64, audioLanguages: [String]?, debugLogging: Bool) {
        discard(reason: "replaced by a new prepare")
        self.debugLogging = debugLogging
        let bridge = AetherPlayerBridgeImpl()
        if let audioLanguages { bridge.applyAudioLanguagePreferences(languages: audioLanguages) }
        bridge.onLoadFailed = { [weak self, weak bridge] message in
            guard let self, let bridge, self.bridge === bridge else { return }
            self.failed = true
            self.log("prepare failed: \(message)")
            // Not from inside the engine's own callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.bridge === bridge else { return }
                self.discard(reason: "load failed")
            }
        }
        self.bridge = bridge
        self.arguments = arguments
        failed = false
        preparedAt = Date()
        bridge.prepareFileWithAudio(
            videoUrl: arguments.videoUrl,
            headersJson: arguments.headersJson,
            subtitlesJson: arguments.subtitlesJson,
            startPositionMs: startPositionMs
        )
        log("prepare start startMs=\(startPositionMs) headers=\(arguments.headersJson != nil) subtitles=\(arguments.subtitlesJson != nil)")
    }

    /// Asked by an outgoing AetherEngine before it tears down: true keeps the audio session up for
    /// the prepared engine. If nothing adopts it soon, the preparation is dropped and the session with it.
    func holdsAudioSessionForHandoff() -> Bool {
        guard bridge != nil, !failed else { return false }
        sessionHeldForHandoff = true
        let pending = bridge
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handoffTimeout) { [weak self] in
            guard let self, let pending, self.bridge === pending, self.sessionHeldForHandoff else { return }
            self.discard(reason: "not adopted after the previous engine left")
        }
        return true
    }

    /// The prepared engine, when it was prepared for exactly [arguments] and is healthy. Otherwise the
    /// preparation is discarded and nil returned, so the caller loads as before.
    func take(matching arguments: Arguments) -> AetherPlayerBridgeImpl? {
        guard let bridge, let prepared = self.arguments else { return nil }
        guard prepared == arguments, !failed, bridge.getErrorMessage().isEmpty else {
            log(
                "prepared stream not used: url same=\(prepared.videoUrl == arguments.videoUrl) " +
                    "headers same=\(prepared.headersJson == arguments.headersJson) " +
                    "subtitles same=\(prepared.subtitlesJson == arguments.subtitlesJson) failed=\(failed)"
            )
            discard(reason: "load did not match")
            return nil
        }
        log(
            "adopting prepared engine loading=\(bridge.getIsLoading()) " +
                "buffered=\(String(format: "%.1f", bridge.preparedBufferedSeconds))s " +
                "age=\(Int(Date().timeIntervalSince(preparedAt)))s"
        )
        self.bridge = nil
        self.arguments = nil
        sessionHeldForHandoff = false
        bridge.onLoadFailed = nil
        return bridge
    }

    func discard(reason: String) {
        guard let bridge else { return }
        log("discarded: \(reason)")
        self.bridge = nil
        arguments = nil
        failed = false
        // A prepared engine never owned the session; it belongs to the engine that is playing.
        bridge.destroy(keepAudioSession: true)
        if sessionHeldForHandoff {
            // The engine that kept the session for this handoff is gone and nothing took it over.
            sessionHeldForHandoff = false
            let session = PlayerAudioSessionController()
            session.allowsMultichannelContent = true
            session.deactivate()
            AetherNowPlayingController.clearIfOrphaned(reason: reason)
        }
    }

    private func log(_ line: @autoclosure () -> String) {
        guard debugLogging else { return }
        print("[NextEp][aether] \(line())")
    }
}
