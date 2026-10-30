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

    /// Host diagnostics for transport and background handling (the app's `[NowPlaying]` lines).
    public var onDiagnostic: ((String) -> Void)?

    public private(set) var audioTracks: [NuvioAetherTrack] = []
    public private(set) var subtitleTracks: [NuvioAetherTrack] = []
    public private(set) var errorMessage = ""

    /// Cues of the selected subtitle track (text and bitmap), for the host overlays.
    public private(set) var subtitleCues: [NuvioAetherSubtitleCue] = []
    /// Called on the main thread whenever `subtitleCues` changes.
    public var onSubtitleCuesChanged: (([NuvioAetherSubtitleCue]) -> Void)?

    /// Set while the selected track is styled ASS/SSA whose cues carry raw events (`assEvents`).
    public private(set) var subtitleASSSource: NuvioAetherASSSource?
    /// Called on the main thread whenever `subtitleASSSource` changes.
    public var onSubtitleASSSourceChanged: ((NuvioAetherASSSource?) -> Void)?

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
    /// False for a next-episode prepare: the load settles paused rather than letting the engine's
    /// terminal play() start it (and its audio) before the pause lands.
    private var autoplayOnLoad = true
    private var isLoadInFlight = false
    private var isLoaded = false
    private var hasRenderedFirstFrame = false
    private var hasReportedLoadFailure = false
    private var pendingSeekSeconds: Double?
    private var requestedSpeed: Float = 1.0
    private var requestedVolume: Float = 1.0
    private var isMuted = false
    /// The engine released the session while the app sat paused in the background (its grace window
    /// ran out). It keeps the position and track selection but does not rebuild on its own.
    private var isSessionTornDown = false
    private var foregroundObserver: NSObjectProtocol?

    public init() throws {
        engine = try AetherEngine()
        // Playback continues with the screen locked or the app in the background (unlike mpv, which
        // pauses). Paused in the background, the engine releases the session after its grace window;
        // the next play() rebuilds it (see `rebuildTornDownSession`).
        engine.backgroundPlaybackEnabled = true
        surface = AetherPlayerView()
        view = surface
        engine.bind(view: surface)
        observeEngine()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Back on screen paused: bring the picture back rather than waiting for play().
            Task { @MainActor [weak self] in
                guard let self, self.isSessionTornDown else { return }
                self.rebuildTornDownSession(reason: "foreground")
            }
        }
    }

    deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    // MARK: - Observation

    private func observeEngine() {
        if NuvioAetherDebug.pgsLogging { observeEngineForDebugLogging() }
        if NuvioAetherDebug.stallLogging { observeEngineForStallLogging() }
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

        engine.$isSessionReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self, !ready, self.isLoaded, !self.isLoadInFlight,
                      UIApplication.shared.applicationState == .background else { return }
                self.isSessionTornDown = true
                self.onDiagnostic?("engine released the session in the background at \(Int(self.engine.clock.currentTime))s")
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
                self.logBitmapCues(engineCues: cues, mapped: mapped)
                guard mapped != self.subtitleCues else { return }
                self.subtitleCues = mapped
                self.onSubtitleCuesChanged?(mapped)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(engine.$activeSubtitleTrackIndex, engine.$subtitleTracks, engine.$sidecarASSHeader)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activeId, tracks, sidecarHeader in
                guard let self else { return }
                let source = activeId.flatMap { id -> NuvioAetherASSSource? in
                    guard let track = tracks.first(where: { $0.id == id }) else { return nil }
                    // An external file's header comes from its sidecar decode, an embedded track's from
                    // the container; either is only set when the cues carry raw ASS events.
                    let header = (track.isExternal ? sidecarHeader : track.assHeader)?
                        .replacingOccurrences(of: "\0", with: "")
                    guard let header, !header.isEmpty else { return nil }
                    return NuvioAetherASSSource(trackId: id, header: header)
                }
                guard source != self.subtitleASSSource else { return }
                self.subtitleASSSource = source
                self.onSubtitleASSSourceChanged?(source)
            }
            .store(in: &cancellables)
    }

    /// `NuvioAetherDebug.pgsLogging` only: the route and track selection behind the cue lines below.
    private func observeEngineForDebugLogging() {
        NuvioAetherDebug.installEngineLogForwarding()
        engine.$videoRoute
            .receive(on: DispatchQueue.main)
            .sink { route in NuvioAetherDebug.log("videoRoute=\(route.rawValue)") }
            .store(in: &cancellables)
        engine.$activeSubtitleTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self else { return }
                let track = id.flatMap { id in self.engine.subtitleTracks.first { $0.id == id } }
                NuvioAetherDebug.log("activeSubtitle id=\(id.map(String.init) ?? "nil") codec=\(track?.codec ?? "-") "
                    + "name=\(track?.name ?? "-") external=\(track?.isExternal ?? false) route=\(self.engine.videoRoute.rawValue)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Stall diagnostics (`NuvioAetherDebug.stallLogging`)

    private var stallSampler: Timer?
    private var stallObservers: [NSObjectProtocol] = []
    private lazy var stallTag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000)

    private func stallLog(_ line: String) {
        NuvioAetherDebug.stall("p\(stallTag) \(line)")
    }

    private func observeEngineForStallLogging() {
        NuvioAetherDebug.installEngineLogForwarding()
        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.stallLog("phase -> \(phase) \(self?.stallSnapshot() ?? "")") }
            .store(in: &cancellables)
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.stallLog("state -> \(state)") }
            .store(in: &cancellables)
        engine.$isSessionReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in self?.stallLog("isSessionReady -> \(ready)") }
            .store(in: &cancellables)
        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "app didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "app willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "app didBecomeActive"),
            (UIApplication.willResignActiveNotification, "app willResignActive"),
            (UIApplication.didReceiveMemoryWarningNotification, "app memory warning"),
            (AVAudioSession.interruptionNotification, "audio interruption"),
        ]
        stallObservers = events.map { name, label in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo.map { " \($0)" } ?? ""
                Task { @MainActor [weak self] in self?.stallLog("\(label)\(info) \(self?.stallSnapshot() ?? "")") }
            }
        }
        let sampler = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLoaded || self.isLoadInFlight else { return }
                self.stallLog("sample \(self.stallSnapshot())")
            }
        }
        RunLoop.main.add(sampler, forMode: .common)
        stallSampler = sampler
    }

    private func stopStallLogging() {
        stallSampler?.invalidate()
        stallSampler = nil
        stallObservers.forEach(NotificationCenter.default.removeObserver)
        stallObservers = []
    }

    private func stallSnapshot() -> String {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let pos = engine.clock.currentTime
        let dur = engine.duration
        let pct = dur > 0 ? String(format: "%.1f%%", pos / dur * 100) : "-"
        return "app=\(appState) phase=\(engine.playbackPhase) state=\(engine.state) "
            + "pos=\(String(format: "%.1f", pos)) buf=\(String(format: "%.1f", engine.clock.bufferedPosition)) "
            + "dur=\(String(format: "%.1f", dur)) pct=\(pct) wantsPlay=\(wantsPlay) loaded=\(isLoaded) "
            + "inFlight=\(isLoadInFlight) tornDown=\(isSessionTornDown) ready=\(engine.isSessionReady) "
            + "route=\(engine.videoRoute.rawValue) err=\(errorMessage.isEmpty ? "-" : errorMessage)"
    }

    private func logBitmapCues(engineCues: [SubtitleCue], mapped: [NuvioAetherSubtitleCue]) {
        guard NuvioAetherDebug.pgsLogging else { return }
        let images: [(cue: SubtitleCue, image: SubtitleImage)] = engineCues.compactMap { cue in
            if case .image(let image) = cue.body { return (cue, image) }
            return nil
        }
        let clock = engine.clock.sourceTime
        let mappedBitmaps = mapped.filter { $0.bitmap != nil }.count
        NuvioAetherDebug.log("cues total=\(engineCues.count) image=\(images.count) mappedBitmap=\(mappedBitmaps) "
            + "clock=\(String(format: "%.3f", clock)) route=\(engine.videoRoute.rawValue)")
        // The cues around the playhead: what should be on screen now and next.
        let nearby = images
            .filter { $0.cue.endTime > clock - 2 }
            .sorted { $0.cue.startTime < $1.cue.startTime }
            .prefix(3)
        for (cue, image) in nearby {
            NuvioAetherDebug.log("  cue id=\(cue.id) start=\(String(format: "%.3f", cue.startTime)) "
                + "end=\(String(format: "%.3f", cue.endTime)) active=\(cue.startTime <= clock && clock < cue.endTime) "
                + "canvas=\(Int(image.canvasSize.width))x\(Int(image.canvasSize.height)) "
                + "img=\(image.cgImage.width)x\(image.cgImage.height) pos=\(image.position) forced=\(image.isForced)")
        }
    }

    // MARK: - Loading

    /// Loads a new stream. `externalSubtitles` are listed as tracks without being selected, like
    /// mpv's `sub-add auto`.
    public func load(
        url: URL,
        headers: [String: String],
        externalSubtitles: [NuvioAetherExternalSubtitle] = [],
        startPositionSeconds: Double? = nil,
        autoplay: Bool = true
    ) {
        lastURL = url
        lastHeaders = headers
        declaredExternalSubtitles = externalSubtitles
        addedExternalSubtitles = []
        pendingSubtitleSelection = nil
        autoplayOnLoad = autoplay
        startLoad(startPositionSeconds: startPositionSeconds)
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
        isSessionTornDown = false
        isLoaded = false
        hasRenderedFirstFrame = false
        hasReportedLoadFailure = false

        var options = LoadOptions()
        options.autoplay = autoplayOnLoad || wantsPlay
        options.httpHeaders = headers
        // Decode-confirm E-AC-3 JOC so isAtmos is accurate rather than a container guess.
        options.confirmAtmos = true
        options.preferredAudioLanguages = preferredAudioLanguages
        // Subtitle auto-selection stays with the Nuvio player (it picks from the track list itself),
        // so preferredSubtitleLanguages is deliberately left empty.
        options.externalSubtitles = externalSubtitles.map(\.engineTrack)
        // ASS/SSA cues keep their raw events (and tracks their header) for the host's libass renderer;
        // other formats are unaffected.
        options.preserveASSMarkup = true

        let startPosition = startPositionSeconds ?? pendingSeekSeconds
        pendingSeekSeconds = nil
        isLoadInFlight = true

        stallLog("load start=\(startPosition.map { String(format: "%.1f", $0) } ?? "nil") autoplay=\(options.autoplay) "
            + "host=\(url.host ?? "-") file=\(url.lastPathComponent)")
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

    /// Reopens a session the engine released in the background, at its position and with its tracks,
    /// then applies what was asked for meanwhile (play / pause, a seek). Until it is back the player
    /// reports loading and queues transport like a first load.
    private func rebuildTornDownSession(reason: String) {
        guard isSessionTornDown else { return }
        isSessionTornDown = false
        isLoaded = false
        isLoadInFlight = true
        onDiagnostic?("rebuilding the released session (\(reason)) wantsPlay=\(wantsPlay)")
        let engine = self.engine
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            do {
                try await engine.reloadAtCurrentPosition()
                guard let self, !Task.isCancelled else { return }
                self.isLoadInFlight = false
                self.isLoaded = true
                if let target = self.pendingSeekSeconds {
                    self.pendingSeekSeconds = nil
                    await engine.seek(to: target)
                }
                self.applyPendingSubtitleSelection()
                self.registerPendingExternalSubtitles()
                if self.wantsPlay { engine.play() } else { engine.pause() }
                self.onDiagnostic?("session rebuilt at \(Int(engine.clock.currentTime))s playing=\(self.wantsPlay)")
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.onDiagnostic?("session rebuild failed: \(error.localizedDescription)")
                self.failLoad(error.localizedDescription)
            }
        }
    }

    public func retry() {
        let position = engine.clock.currentTime
        reload(startPositionSeconds: position > 0 ? position : nil)
    }

    public func destroy() {
        onLoadFailed = nil
        onSubtitleCuesChanged = nil
        onSubtitleASSSourceChanged = nil
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
        isSessionTornDown = false
        stallLog("destroy \(stallSnapshot())")
        stopStallLogging()
        engine.stop()
        engine.unbind(view: surface)
    }

    // MARK: - Transport

    public func play() {
        wantsPlay = true
        if isSessionTornDown {
            rebuildTornDownSession(reason: "play")
            return
        }
        guard isLoaded else { return }
        if isEnded {
            // Stays on the last frame, as mpv does with keep-open: a play() after the end (a resumed
            // transport state, a system control) must not restart the episode under the next-episode
            // flow. A restart comes as seek(toSeconds: 0) first, which reloads (.ended is terminal).
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
        if isSessionTornDown {
            pendingSeekSeconds = target
            rebuildTornDownSession(reason: "seek")
            return
        }
        guard isLoaded else {
            pendingSeekSeconds = target
            return
        }
        if isEnded {
            // A seek at or past the end (a +10 s skip on the last frame) keeps the episode ended.
            if engine.duration > 0, target >= engine.duration - 1 { return }
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

    /// Whether playback was asked for (play() since the last pause()), even while the engine is still
    /// loading or the system has paused it.
    public var wantsPlayback: Bool { wantsPlay }

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

    /// Shape of the picture as presented (coded size under the pixel aspect), nil before it is known.
    /// Subtitle layers fit this into the view the same way the video gravity does.
    public var videoDisplaySize: CGSize? {
        if let size = engine.softwareDisplaySize, size.width > 0, size.height > 0 { return size }
        let width = Double(engine.sourceVideoWidth)
        let height = Double(engine.sourceVideoHeight)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width * engine.sourceVideoPixelAspectRatio, height: height)
    }

    /// Fonts attached to the current media, for ASS styles that name them. Read once per load: the
    /// payloads can be tens of MB.
    public var fontAttachments: [NuvioAetherFontAttachment] {
        engine.fontAttachments.map { NuvioAetherFontAttachment(name: $0.filename, data: $0.data) }
    }

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
