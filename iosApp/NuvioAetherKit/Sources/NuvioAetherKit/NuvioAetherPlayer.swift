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

    /// Text cues of the selected subtitle track, for the host overlay. Bitmap cues are left out.
    public private(set) var subtitleCues: [NuvioAetherSubtitleCue] = []
    /// Called on the main thread whenever `subtitleCues` changes.
    public var onSubtitleCuesChanged: (([NuvioAetherSubtitleCue]) -> Void)?

    private let engine: AetherEngine
    private let surface: AetherPlayerView
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var lastURL: URL?
    private var lastHeaders: [String: String] = [:]
    /// External subtitles that came with the stream.
    private var declaredExternalSubtitles: [NuvioAetherExternalSubtitle] = []
    /// External subtitles added mid-session (addon picks); declared again on an internal reload.
    private var addedExternalSubtitles: [NuvioAetherExternalSubtitle] = []
    /// Engine track id of each registered external subtitle in the current session.
    private var externalSubtitleIds: [Int: NuvioAetherExternalSubtitle] = [:]
    /// External subtitles requested before the current load finished; registered once it has.
    private var pendingExternalSubtitles: [(subtitle: NuvioAetherExternalSubtitle, select: Bool)] = []
    /// Subtitle selection to apply once the current load finishes: one made while loading, or the one
    /// an internal reload (retry, replay) carries over.
    private var pendingSubtitleSelection: SubtitleSelection?

    private enum SubtitleSelection {
        case off
        case embedded(Int)
        case external(NuvioAetherExternalSubtitle)
    }

    private var wantsPlay = false
    private var isLoadInFlight = false
    private var isLoaded = false
    private var hasRenderedFirstFrame = false
    private var hasReportedLoadFailure = false
    private var pendingSeekSeconds: Double?
    private var requestedSpeed: Float = 1.0
    private var requestedVolume: Float = 1.0
    private var isMuted = false

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

        Publishers.CombineLatest(engine.$subtitleTracks, engine.$activeSubtitleTrackIndex)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks, activeId in
                self?.subtitleTracks = tracks.enumerated().map { offset, track in
                    NuvioAetherTrack(
                        index: offset,
                        id: track.id,
                        title: Self.subtitleTitle(
                            Self.trackTitle(
                                name: track.name,
                                language: track.language,
                                codec: track.codec,
                                channels: 0,
                                isAtmos: false,
                                fallback: "Subtitle \(offset + 1)"
                            ),
                            isForced: track.isForced
                        ),
                        language: track.language ?? "",
                        selected: track.id == activeId
                    )
                }
            }
            .store(in: &cancellables)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                let mapped = cues.compactMap(NuvioAetherSubtitleCue.make(from:))
                guard mapped != self.subtitleCues else { return }
                self.subtitleCues = mapped
                self.onSubtitleCuesChanged?(mapped)
            }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    /// Loads a new stream. `externalSubtitles` are listed as tracks without being selected, like
    /// mpv's `sub-add auto`.
    public func load(url: URL, headers: [String: String], externalSubtitles: [NuvioAetherExternalSubtitle] = []) {
        lastURL = url
        lastHeaders = headers
        declaredExternalSubtitles = externalSubtitles
        addedExternalSubtitles = []
        pendingSubtitleSelection = nil
        startLoad(startPositionSeconds: nil)
    }

    /// Reloads the current stream (AetherEngine sessions do not survive retry or the end of playback),
    /// keeping addon subtitles and the subtitle selection, as mpv re-applies them on reload.
    private func reload(startPositionSeconds: Double?) {
        guard lastURL != nil else { return }
        if pendingSubtitleSelection == nil {
            pendingSubtitleSelection = currentSubtitleSelection()
        }
        startLoad(startPositionSeconds: startPositionSeconds)
    }

    private func startLoad(startPositionSeconds: Double?) {
        guard let url = lastURL else { return }
        let headers = lastHeaders
        loadTask?.cancel()
        let externalSubtitles = declaredExternalSubtitles + addedExternalSubtitles
        externalSubtitleIds = [:]
        errorMessage = ""
        isLoaded = false
        hasRenderedFirstFrame = false
        hasReportedLoadFailure = false

        var options = LoadOptions()
        options.httpHeaders = headers
        // Decode-confirm E-AC-3 JOC so isAtmos is accurate rather than a container guess.
        options.confirmAtmos = true
        options.preferredAudioLanguages = preferredAudioLanguages
        // Subtitle auto-selection stays with the Nuvio player (it picks from the track list itself),
        // so preferredSubtitleLanguages is deliberately left empty.
        options.externalSubtitles = externalSubtitles.map(\.engineTrack)

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
                self.externalSubtitleIds = Dictionary(uniqueKeysWithValues: externalSubtitles.enumerated().map {
                    (AetherEngine.externalSubtitleTrackIDBase + $0.offset, $0.element)
                })
                self.applyPendingSubtitleSelection()
                self.registerPendingExternalSubtitles()
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
        let position = engine.clock.currentTime
        reload(startPositionSeconds: position > 0 ? position : nil)
    }

    public func destroy() {
        onLoadFailed = nil
        onSubtitleCuesChanged = nil
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
        if isEnded {
            // .ended is terminal on AetherEngine; replay is a fresh load.
            reload(startPositionSeconds: 0)
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
        if isEnded {
            reload(startPositionSeconds: target)
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

    /// Selects a subtitle track by `NuvioAetherTrack.id`; a negative id turns subtitles off.
    public func selectSubtitleTrack(id: Int) {
        let selection: SubtitleSelection
        if id < 0 {
            selection = .off
        } else if let external = externalSubtitleIds[id] {
            selection = .external(external)
        } else {
            selection = .embedded(id)
        }
        guard isLoaded else {
            pendingSubtitleSelection = selection
            return
        }
        apply(selection)
    }

    private func apply(_ selection: SubtitleSelection) {
        switch selection {
        case .off:
            engine.clearSubtitle()
        case .embedded(let id):
            guard engine.subtitleTracks.contains(where: { $0.id == id }) else { return }
            engine.selectSubtitleTrack(index: id)
        case .external(let subtitle):
            guard let id = externalSubtitleIds.first(where: { $0.value == subtitle })?.key else { return }
            engine.selectSubtitleTrack(index: id)
        }
    }

    private func applyPendingSubtitleSelection() {
        guard let selection = pendingSubtitleSelection else { return }
        pendingSubtitleSelection = nil
        apply(selection)
    }

    private func currentSubtitleSelection() -> SubtitleSelection {
        guard let id = engine.activeSubtitleTrackIndex else { return .off }
        if let external = externalSubtitleIds[id] { return .external(external) }
        return .embedded(id)
    }

    /// Loads an external subtitle file as a track, optionally selecting it (like mpv's `sub-add select`).
    public func addExternalSubtitle(_ subtitle: NuvioAetherExternalSubtitle, select: Bool) {
        guard isLoaded else {
            pendingExternalSubtitles.append((subtitle, select))
            return
        }
        let track = engine.addExternalSubtitleTrack(subtitle.engineTrack)
        addedExternalSubtitles.append(subtitle)
        externalSubtitleIds[track.id] = subtitle
        if select { engine.selectSubtitleTrack(index: track.id) }
    }

    /// Removes every external subtitle track (like mpv's `sub-remove` over all external tracks), then
    /// selects the embedded track `selectId`, or turns subtitles off when it is negative.
    public func removeExternalSubtitles(thenSelect selectId: Int) {
        pendingExternalSubtitles.removeAll()
        addedExternalSubtitles.removeAll()
        guard isLoaded else {
            selectSubtitleTrack(id: selectId)
            return
        }
        for track in engine.subtitleTracks where track.isExternal {
            engine.removeExternalSubtitleTrack(id: track.id)
            externalSubtitleIds[track.id] = nil
        }
        selectSubtitleTrack(id: selectId)
    }

    private func registerPendingExternalSubtitles() {
        let pending = pendingExternalSubtitles
        pendingExternalSubtitles.removeAll()
        for entry in pending {
            addExternalSubtitle(entry.subtitle, select: entry.select)
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
    /// Source PTS of the frame on screen (~10 Hz), the axis `subtitleCues` are timed on. Holds the
    /// displayed frame during a seek rather than jumping to the target.
    public var subtitleClockSeconds: Double { engine.clock.sourceTime }
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

    /// The Nuvio player recognises forced tracks by their label, so surface the container flag there.
    private static func subtitleTitle(_ title: String, isForced: Bool) -> String {
        guard isForced, !title.localizedCaseInsensitiveContains("forced") else { return title }
        return "\(title) [Forced]"
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
