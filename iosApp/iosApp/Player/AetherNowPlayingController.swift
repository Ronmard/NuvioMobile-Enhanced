import Foundation
import UIKit
import MediaPlayer

/// Temporary diagnostics for remote controls and Now Playing on the AetherEngine path.
enum AetherNowPlayingDebug {
    static let enabled = false

    static func log(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        print("[NowPlaying] \(line())")
    }
}

/// Remote commands and system Now Playing for the AetherEngine path.
///
/// Uses the shared `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter`, as the mpv path does, and no
/// engine-owned `MPNowPlayingSession` (`ownsVideoNowPlayingSession` stays off), so the native path,
/// the software path and an adopted next episode all go through the same code.
///
/// Several Aether players can exist at once (the one playing and a prepared next episode), so only
/// the controller that was last activated touches the shared centers; any other one only removes its
/// own command targets.
///
/// The engine's state is polled rather than observed: a tick republishes when play/pause, duration
/// or speed changed, or when the position drifted from what iOS extrapolates (a seek), so pause,
/// seeks, speed changes and track-switch reloads all land within one tick.
final class AetherNowPlayingController {
    private struct RemoteCommandTarget {
        let command: MPRemoteCommand
        let token: Any
    }

    private struct Metadata {
        var title: String?
        var subtitle: String?
    }

    private struct PlaybackState: Equatable {
        var isPlaying = false
        var positionMs: Int64 = 0
        var durationMs: Int64 = 0
        var playbackSpeed: Float = 1.0
    }

    private(set) static weak var current: AetherNowPlayingController?
    /// Shared so an adopted next episode with the same artwork does not fetch it again.
    private static let artworkCache = NSCache<NSString, UIImage>()
    private static let positionDriftToleranceMs: Double = 1_500
    private static let syncInterval: TimeInterval = 0.5

    private weak var owner: AetherPlayerViewController?
    private var remoteTargets: [RemoteCommandTarget] = []
    private let id = UUID().uuidString.prefix(4)
    private var metadata = Metadata()
    private var currentArtworkURL: String?
    private var currentArtworkImage: UIImage?
    private var artworkTask: URLSessionDataTask?
    private var publishedState: PlaybackState?
    private var publishedAt: TimeInterval = 0
    private var syncTimer: Timer?

    init(owner: AetherPlayerViewController) {
        self.owner = owner
    }

    deinit {
        syncTimer?.invalidate()
        artworkTask?.cancel()
        remoteTargets.forEach { $0.command.removeTarget($0.token) }
    }

    var isCurrent: Bool { Self.current === self }

    /// This player is the one on screen: it takes the system controls.
    func activate() {
        if let previous = Self.current, previous !== self {
            AetherNowPlayingDebug.log("[\(id)] activate, taking over from [\(previous.id)]")
            previous.removeRemoteCommandTargets()
            previous.stopSyncTimer()
        } else {
            AetherNowPlayingDebug.log("[\(id)] activate")
        }
        Self.current = self
        UIApplication.shared.beginReceivingRemoteControlEvents()
        configureRemoteCommands()
        publishedState = nil
        startSyncTimer()
        sync()
    }

    /// The player is going away (or failed to load). Only the current controller clears Now Playing
    /// and disables the commands. [keepPublishedInfo] is for a handoff to a prepared next episode:
    /// the card and the commands stay up (paused) until the incoming player publishes its own.
    func resign(reason: String, keepPublishedInfo: Bool = false) {
        removeRemoteCommandTargets()
        stopSyncTimer()
        artworkTask?.cancel()
        artworkTask = nil
        guard isCurrent else { return }
        AetherNowPlayingDebug.log("[\(id)] resign (\(reason)) keepInfo=\(keepPublishedInfo)")
        Self.current = nil
        publishedState = nil
        if keepPublishedInfo {
            let center = MPNowPlayingInfoCenter.default()
            if var info = center.nowPlayingInfo {
                info[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
                center.nowPlayingInfo = info
            }
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            setCommandsEnabled(false)
        }
    }

    /// A handoff kept the outgoing card up, and no player took it over.
    static func clearIfOrphaned(reason: String) {
        guard current == nil else { return }
        AetherNowPlayingDebug.log("clear orphaned card (\(reason))")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        for command in [
            center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
            center.skipForwardCommand, center.skipBackwardCommand, center.changePlaybackPositionCommand,
            center.nextTrackCommand, center.previousTrackCommand,
        ] {
            command.isEnabled = false
        }
    }

    // MARK: - Metadata

    func updateMetadata(title: String, subtitle: String?, artworkUrl: String?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artworkUrl = artworkUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = metadata.title != title || metadata.subtitle != subtitle || currentArtworkURL != artworkUrl
        guard changed else { return }
        AetherNowPlayingDebug.log("[\(id)] metadata title=\"\(title)\" subtitle=\"\(subtitle ?? "")\" artwork=\(artworkUrl != nil)")
        metadata = Metadata(title: title, subtitle: subtitle)
        if artworkUrl != currentArtworkURL {
            loadArtwork(artworkUrl)
        }
        publish(reason: "metadata")
    }

    /// Kotlin left the player: forget the item and, when this player holds the card, take it down.
    func clearInfo() {
        metadata = Metadata()
        currentArtworkURL = nil
        currentArtworkImage = nil
        artworkTask?.cancel()
        artworkTask = nil
        publishedState = nil
        guard isCurrent else { return }
        AetherNowPlayingDebug.log("[\(id)] clear info")
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func loadArtwork(_ urlString: String?) {
        currentArtworkURL = urlString
        currentArtworkImage = nil
        artworkTask?.cancel()
        artworkTask = nil
        guard let urlString, !urlString.isEmpty else { return }
        if let cached = Self.artworkCache.object(forKey: urlString as NSString) {
            currentArtworkImage = cached
            return
        }
        guard let url = URL(string: urlString) else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Self.artworkCache.setObject(image, forKey: urlString as NSString)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentArtworkURL == urlString else { return }
                self.currentArtworkImage = image
                self.publish(reason: "artwork")
            }
        }
        artworkTask = task
        task.resume()
    }

    // MARK: - Playback state

    private func startSyncTimer() {
        guard syncTimer == nil else { return }
        let timer = Timer(timeInterval: Self.syncInterval, repeats: true) { [weak self] _ in self?.sync() }
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    private func currentPlaybackState() -> PlaybackState? {
        guard let owner else { return nil }
        let speed = owner.currentSpeed
        return PlaybackState(
            // Buffering and seeking hold the clock, so iOS should not run it on.
            isPlaying: owner.isPlayerPlaying && !owner.isPlayerLoading,
            positionMs: max(0, owner.positionMs),
            durationMs: max(0, owner.durationMs),
            playbackSpeed: speed > 0 ? speed : 1.0
        )
    }

    func sync() {
        guard isCurrent, let next = currentPlaybackState() else { return }
        refreshSkipIntervals()
        guard metadata.title?.isEmpty == false else { return }

        guard let published = publishedState else {
            publish(reason: "first")
            return
        }
        // Something outside this controller (mpv's controller tearing down) took the card down.
        if MPNowPlayingInfoCenter.default().nowPlayingInfo == nil {
            publish(reason: "info was cleared elsewhere")
            return
        }
        if !MPRemoteCommandCenter.shared().playCommand.isEnabled {
            AetherNowPlayingDebug.log("[\(id)] commands were disabled elsewhere, re-enabling")
            setCommandsEnabled(true)
        }

        if published.isPlaying != next.isPlaying {
            publish(reason: next.isPlaying ? "playing" : "paused")
            return
        }
        if published.durationMs != next.durationMs || published.playbackSpeed != next.playbackSpeed {
            publish(reason: "duration/speed")
            return
        }
        // Where iOS currently believes playback is, based on what was last published.
        let elapsedSincePublish = ProcessInfo.processInfo.systemUptime - publishedAt
        let rate = published.isPlaying ? Double(published.playbackSpeed) : 0
        let expectedPositionMs = Double(published.positionMs) + elapsedSincePublish * 1_000 * rate
        if abs(Double(next.positionMs) - expectedPositionMs) > Self.positionDriftToleranceMs {
            publish(reason: "position moved (expected \(Int(expectedPositionMs / 1000))s)")
        }
    }

    private func publish(reason: String) {
        guard isCurrent, let title = metadata.title, !title.isEmpty, let state = currentPlaybackState() else { return }
        publishedState = state
        publishedAt = ProcessInfo.processInfo.systemUptime

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let subtitle = metadata.subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        if state.durationMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(state.durationMs) / 1000.0
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(state.positionMs) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(state.isPlaying ? state.playbackSpeed : 0.0)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = state.durationMs <= 0
        if let artwork = currentArtworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        AetherNowPlayingDebug.log(
            "[\(id)] publish (\(reason)) pos=\(state.positionMs / 1000)s dur=\(state.durationMs / 1000)s " +
                "rate=\(state.isPlaying ? state.playbackSpeed : 0) art=\(currentArtworkImage != nil)"
        )
    }

    // MARK: - Remote commands

    private func setCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = enabled
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
        // AirPods double / triple press and headset next / previous: skip forward / back.
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
    }

    /// The lock screen's skip buttons show the app's skip steps; refreshed when they may have changed.
    func refreshSkipIntervals() {
        guard isCurrent, let owner else { return }
        let center = MPRemoteCommandCenter.shared()
        let forward = NSNumber(value: Double(owner.systemSkipStepMs(forward: true)) / 1000.0)
        let backward = NSNumber(value: Double(owner.systemSkipStepMs(forward: false)) / 1000.0)
        if center.skipForwardCommand.preferredIntervals != [forward] {
            center.skipForwardCommand.preferredIntervals = [forward]
        }
        if center.skipBackwardCommand.preferredIntervals != [backward] {
            center.skipBackwardCommand.preferredIntervals = [backward]
        }
    }

    private func configureRemoteCommands() {
        setCommandsEnabled(true)
        refreshSkipIntervals()
        guard remoteTargets.isEmpty else { return }

        let center = MPRemoteCommandCenter.shared()

        addTarget(center.playCommand, name: "play") { owner, _ in
            owner.requestSystemPlaying(true)
        }
        addTarget(center.pauseCommand, name: "pause") { owner, _ in
            owner.requestSystemPlaying(false)
        }
        addTarget(center.togglePlayPauseCommand, name: "togglePlayPause") { owner, _ in
            owner.requestSystemPlaying(!owner.isPlayerPlaying)
        }
        // The step is read when the command arrives, so a settings change applies at once.
        let skipForward: (AetherPlayerViewController, MPRemoteCommandEvent) -> Void = { owner, _ in
            owner.requestSystemSeekBy(owner.systemSkipStepMs(forward: true))
        }
        let skipBackward: (AetherPlayerViewController, MPRemoteCommandEvent) -> Void = { owner, _ in
            owner.requestSystemSeekBy(-owner.systemSkipStepMs(forward: false))
        }
        addTarget(center.skipForwardCommand, name: "skipForward", skipForward)
        addTarget(center.skipBackwardCommand, name: "skipBackward", skipBackward)
        addTarget(center.nextTrackCommand, name: "nextTrack", skipForward)
        addTarget(center.previousTrackCommand, name: "previousTrack", skipBackward)
        addTarget(center.changePlaybackPositionCommand, name: "changePlaybackPosition") { owner, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            owner.requestSystemSeekTo(Int64(event.positionTime * 1000.0))
        }
    }

    private func addTarget(
        _ command: MPRemoteCommand,
        name: String,
        _ handle: @escaping (AetherPlayerViewController, MPRemoteCommandEvent) -> Void
    ) {
        let token = command.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            if let position = event as? MPChangePlaybackPositionCommandEvent {
                AetherNowPlayingDebug.log("[\(self.id)] command \(name) to=\(Int(position.positionTime))s")
            } else {
                AetherNowPlayingDebug.log("[\(self.id)] command \(name)")
            }
            DispatchQueue.main.async { [weak self] in
                guard let owner = self?.owner else { return }
                handle(owner, event)
            }
            return .success
        }
        remoteTargets.append(RemoteCommandTarget(command: command, token: token))
    }

    private func removeRemoteCommandTargets() {
        guard !remoteTargets.isEmpty else { return }
        remoteTargets.forEach { $0.command.removeTarget($0.token) }
        remoteTargets.removeAll(keepingCapacity: false)
    }
}
