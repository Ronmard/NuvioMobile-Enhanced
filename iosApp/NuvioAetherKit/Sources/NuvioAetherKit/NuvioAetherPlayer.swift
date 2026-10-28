import Foundation
import UIKit
import AVFoundation
import Combine
@_implementationOnly import AetherEngine

/// A track as the Nuvio player UI lists it. `id` is AetherEngine's container stream index,
/// `index` the position within its list.
public struct NuvioAetherTrack {
    public let index: Int
    public let id: Int
    public let title: String
    public let language: String
    public let selected: Bool
}

/// Owns one AetherEngine session for one Nuvio player surface.
///
/// Keeps the engine's types out of its public API so the app module never imports AetherEngine
/// (and with it a second set of FFmpeg C modules).
@MainActor
public final class NuvioAetherPlayer {

    /// The render surface. Host it in the player view controller's view.
    public let view: UIView

    /// Called once per load when the stream cannot play on AetherEngine: the open fails, the
    /// session errors before its first frame, or the source has audio none of which can be delivered.
    public var onLoadFailed: ((String) -> Void)?

    public var preferredAudioLanguages: [String] = []

    public private(set) var audioTracks: [NuvioAetherTrack] = []
    public private(set) var subtitleTracks: [NuvioAetherTrack] = []
    public private(set) var errorMessage = ""

    private let engine: AetherEngine
    private let surface: AetherPlayerView
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var lastURL: URL?
    private var lastHeaders: [String: String] = [:]

    private var wantsPlay = false
    private var isLoadInFlight = false
    private var isLoaded = false
    private var hasRenderedFirstFrame = false
    private var hasReportedLoadFailure = false
    private var pendingSeekSeconds: Double?
    private var requestedSpeed: Float = 1.0
    private var requestedVolume: Float = 1.0
    private var isMuted = false
    /// Subtitle selection is remembered for the picker only; cues are not rendered yet.
    private var selectedSubtitleId: Int?

    public init() throws {
        engine = try AetherEngine()
        // Nuvio pauses when the app backgrounds (the bridge reports no background playback), as on mpv.
        engine.backgroundPlaybackEnabled = false
        surface = AetherPlayerView()
        view = surface
        engine.bind(view: surface)
        observeEngine()
    }

    // MARK: - Observation

    private func observeEngine() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, case .error(let message) = state else { return }
                if self.hasRenderedFirstFrame {
                    self.errorMessage = message
                } else {
                    self.failLoad(message)
                }
            }
            .store(in: &cancellables)

        engine.$hasFirstFrameReadyForDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                if ready { self?.hasRenderedFirstFrame = true }
            }
            .store(in: &cancellables)

        engine.$audioDelivery
            .receive(on: DispatchQueue.main)
            .sink { [weak self] delivery in
                // The source has audio but none of it can reach the renderer: playing on would be silent.
                if case .droppedNoPipeline = delivery {
                    self?.failLoad("AetherEngine cannot deliver this stream's audio")
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(engine.$audioTracks, engine.$activeAudioTrackIndex)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks, activeId in
                self?.audioTracks = tracks.enumerated().map { offset, track in
                    NuvioAetherTrack(
                        index: offset,
                        id: track.id,
                        title: Self.trackTitle(
                            name: track.name,
                            language: track.language,
                            codec: track.codec,
                            channels: track.channels,
                            isAtmos: track.isAtmos,
                            fallback: "Track \(offset + 1)"
                        ),
                        language: track.language ?? "",
                        selected: track.id == activeId
                    )
                }
            }
            .store(in: &cancellables)

        engine.$subtitleTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                guard let self else { return }
                self.subtitleTracks = tracks.enumerated().map { offset, track in
                    NuvioAetherTrack(
                        index: offset,
                        id: track.id,
                        title: Self.trackTitle(
                            name: track.name,
                            language: track.language,
                            codec: track.codec,
                            channels: 0,
                            isAtmos: false,
                            fallback: "Subtitle \(offset + 1)"
                        ),
                        language: track.language ?? "",
                        selected: track.id == self.selectedSubtitleId
                    )
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    public func load(url: URL, headers: [String: String], startPositionSeconds: Double? = nil) {
        loadTask?.cancel()
        lastURL = url
        lastHeaders = headers
        errorMessage = ""
        isLoaded = false
        hasRenderedFirstFrame = false
        hasReportedLoadFailure = false
        selectedSubtitleId = nil

        var options = LoadOptions()
        options.httpHeaders = headers
        // Decode-confirm E-AC-3 JOC so isAtmos is accurate rather than a container guess.
        options.confirmAtmos = true
        options.preferredAudioLanguages = preferredAudioLanguages

        let startPosition = startPositionSeconds ?? pendingSeekSeconds
        pendingSeekSeconds = nil
        isLoadInFlight = true

        let engine = self.engine
        loadTask = Task { @MainActor [weak self] in
            do {
                try await engine.load(url: url, startPosition: startPosition, options: options)
                guard let self, !Task.isCancelled else { return }
                self.isLoadInFlight = false
                self.isLoaded = true
                engine.volume = self.isMuted ? 0 : min(self.requestedVolume, 1.0)
                if self.requestedSpeed != 1.0 { engine.setRate(self.requestedSpeed) }
                if let target = self.pendingSeekSeconds {
                    self.pendingSeekSeconds = nil
                    await engine.seek(to: target)
                }
                if self.wantsPlay { engine.play() } else { engine.pause() }
            } catch is CancellationError {
                // A newer load superseded this one; not a failure.
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failLoad(error.localizedDescription)
            }
        }
    }

    /// Reports a load failure once per load. Also used by the host for requests it rejects up front.
    public func failLoad(_ message: String) {
        errorMessage = message
        isLoadInFlight = false
        guard !hasReportedLoadFailure else { return }
        hasReportedLoadFailure = true
        print("[AetherPlayer] load failed: \(message)")
        onLoadFailed?(message)
    }

    public func retry() {
        guard let lastURL else { return }
        let position = engine.clock.currentTime
        load(url: lastURL, headers: lastHeaders, startPositionSeconds: position > 0 ? position : nil)
    }

    public func destroy() {
        onLoadFailed = nil
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        engine.stop()
        engine.unbind(view: surface)
    }

    // MARK: - Transport

    public func play() {
        wantsPlay = true
        guard isLoaded else { return }
        if isEnded, let lastURL {
            // .ended is terminal on AetherEngine; replay is a fresh load.
            load(url: lastURL, headers: lastHeaders, startPositionSeconds: 0)
            return
        }
        engine.play()
    }

    public func pause() {
        wantsPlay = false
        guard isLoaded else { return }
        engine.pause()
    }

    public func seek(toSeconds target: Double) {
        let target = max(target, 0)
        guard isLoaded else {
            pendingSeekSeconds = target
            return
        }
        if isEnded, let lastURL {
            load(url: lastURL, headers: lastHeaders, startPositionSeconds: target)
            return
        }
        let engine = self.engine
        Task { @MainActor in await engine.seek(to: target) }
    }

    public func seek(bySeconds offset: Double) {
        let base = pendingSeekSeconds ?? engine.seekTarget ?? engine.clock.currentTime
        seek(toSeconds: base + offset)
    }

    public func setSpeed(_ speed: Float) {
        requestedSpeed = speed
        guard isLoaded else { return }
        engine.setRate(speed)
    }

    public var volume: Float { isMuted ? 0 : requestedVolume }

    public func setVolume(_ volume: Float) {
        requestedVolume = max(volume, 0)
        isMuted = requestedVolume <= 0.001
        // Nuvio allows boosting to 2.0; AetherEngine caps at 1.0.
        engine.volume = min(requestedVolume, 1.0)
    }

    public func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.volume = muted ? 0 : min(requestedVolume, 1.0)
    }

    /// 0 = Fit, 1 = Fill (stretch), 2 = Zoom (crop), matching the bridge's resize modes.
    public func setResizeMode(_ mode: Int) {
        switch mode {
        case 1: engine.videoGravity = .resize
        case 2: engine.videoGravity = .resizeAspectFill
        default: engine.videoGravity = .resizeAspect
        }
    }

    // MARK: - Tracks

    public func selectAudioTrack(id: Int) {
        guard isLoaded, id >= 0 else { return }
        engine.selectAudioTrack(index: id)
    }

    public func selectSubtitleTrack(id: Int) {
        selectedSubtitleId = id >= 0 ? id : nil
        subtitleTracks = subtitleTracks.map {
            NuvioAetherTrack(index: $0.index, id: $0.id, title: $0.title, language: $0.language, selected: $0.id == selectedSubtitleId)
        }
    }

    // MARK: - State

    public var isLoading: Bool {
        if isLoadInFlight { return true }
        switch engine.playbackPhase {
        case .loading, .seeking, .rebuffering, .stalled: return true
        default: return false
        }
    }

    public var isPlaying: Bool {
        if case .playing = engine.state { return true }
        return false
    }

    public var isEnded: Bool {
        if case .ended = engine.state { return true }
        return false
    }

    public var durationSeconds: Double { engine.duration }
    public var positionSeconds: Double {
        if !isLoaded, let pendingSeekSeconds { return pendingSeekSeconds }
        return engine.clock.currentTime
    }
    public var bufferedSeconds: Double { engine.clock.bufferedPosition }
    public var speed: Float { requestedSpeed }
    public var videoWidth: Int { Int(engine.sourceVideoWidth) }
    public var videoHeight: Int { Int(engine.sourceVideoHeight) }

    /// Same keys as the mpv bridge's media info, so the player's Info panel can show them.
    public func mediaInfo() -> [String: Any]? {
        guard isLoaded else { return nil }
        let activeAudio = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
        let hdrFormat: String
        switch engine.videoFormat {
        case .sdr: hdrFormat = ""
        case .hdr10: hdrFormat = "HDR10"
        case .hdr10Plus: hdrFormat = "HDR10+"
        case .dolbyVision: hdrFormat = "Dolby Vision"
        case .hlg: hdrFormat = "HLG"
        }
        let audioCodec = activeAudio.map { $0.isAtmos ? "\($0.codec) (Atmos)" : $0.codec } ?? ""
        let channels = activeAudio?.channels ?? 0
        let fps = engine.sourceVideoFrameRate ?? 0
        return [
            "engine": "AetherEngine",
            "filename": lastURL?.lastPathComponent ?? "",
            "videoCodec": engine.sourceVideoCodecName ?? "",
            "videoDecoder": engine.activeVideoDecoder ?? "",
            "dvProfile": engine.sourceDVProfile.map { "\($0)" } ?? "",
            "codecProfile": "",
            "hdrFormat": hdrFormat,
            "gamma": "",
            "primaries": "",
            "colorLevels": "",
            "pixelFormat": "",
            "videoWidth": Int(engine.sourceVideoWidth),
            "videoHeight": Int(engine.sourceVideoHeight),
            "fps": fps.isFinite ? fps : 0.0,
            "hwdecCurrent": "\(engine.videoRoute)",
            "audioCodec": audioCodec,
            "audioDecoder": engine.activeAudioDecoder ?? "",
            "audioChannels": channels > 0 ? "\(channels)" : "",
            "audioSampleRate": "",
            "audioLang": activeAudio?.language ?? "",
            "videoBitrateKbps": Int(engine.sourceVideoBitrate / 1000),
            "audioBitrateKbps": Int((activeAudio?.bitrate ?? 0) / 1000),
        ]
    }

    private static func trackTitle(
        name: String,
        language: String?,
        codec: String,
        channels: Int,
        isAtmos: Bool,
        fallback: String
    ) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let languageName = language
            .flatMap { $0.isEmpty || $0 == "und" ? nil : $0 }
            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        let base = !trimmedName.isEmpty ? trimmedName : (languageName ?? fallback)
        let channelName: String?
        switch channels {
        case 0: channelName = nil
        case 1: channelName = "Mono"
        case 2: channelName = "Stereo"
        case 6: channelName = "5.1"
        case 8: channelName = "7.1"
        default: channelName = "\(channels)ch"
        }
        let codecName = codec.isEmpty ? nil : codec.uppercased() + (isAtmos ? " Atmos" : "")
        let details = [channelName, codecName]
            .compactMap { $0 }
            .filter { !base.localizedCaseInsensitiveContains($0) }
        return details.isEmpty ? base : "\(base) (\(details.joined(separator: ", ")))"
    }
}
