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
final class AetherNowPlayingController {
    private struct RemoteCommandTarget {
        let command: MPRemoteCommand
        let token: Any
    }

    private(set) static weak var current: AetherNowPlayingController?

    private weak var owner: AetherPlayerViewController?
    private var remoteTargets: [RemoteCommandTarget] = []
    private let id = UUID().uuidString.prefix(4)

    init(owner: AetherPlayerViewController) {
        self.owner = owner
    }

    deinit {
        remoteTargets.forEach { $0.command.removeTarget($0.token) }
    }

    var isCurrent: Bool { Self.current === self }

    /// This player is the one on screen: it takes the system controls.
    func activate() {
        if let previous = Self.current, previous !== self {
            AetherNowPlayingDebug.log("[\(id)] activate, taking over from [\(previous.id)]")
            previous.removeRemoteCommandTargets()
        } else {
            AetherNowPlayingDebug.log("[\(id)] activate")
        }
        Self.current = self
        UIApplication.shared.beginReceivingRemoteControlEvents()
        configureRemoteCommands()
    }

    /// The player is going away (or failed to load). Only the current controller disables the
    /// commands.
    func resign(reason: String) {
        removeRemoteCommandTargets()
        guard isCurrent else { return }
        AetherNowPlayingDebug.log("[\(id)] resign (\(reason))")
        Self.current = nil
        setCommandsEnabled(false)
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
