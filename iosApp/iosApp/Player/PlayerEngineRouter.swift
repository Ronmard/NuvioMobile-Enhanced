import Foundation
import UIKit
import ComposeApp

// MARK: - Player Engine Router

/// Engine values Kotlin sends through `setPreferredEngine` (IosPlayerEngine.bridgeValue).
enum PlayerEngineChoice: String {
    case auto
    case aether
    case mpv
}

/// The bridge Kotlin gets from the factory. Picks AetherEngine or mpv per load and delegates every
/// call to the active engine's bridge.
///
/// - `mpv` (also the default when Kotlin never calls `setPreferredEngine`, e.g. hero trailers):
///   mpv only, exactly as before.
/// - `aether`: AetherEngine only; a stream it cannot play shows its error.
/// - `auto`: AetherEngine first. When it cannot open the stream (see AetherPlayerBridgeImpl.onLoadFailed),
///   or the stream has a separate audio URL, the same load continues on mpv.
///
/// Configuration Kotlin sends before or during playback (output settings, subtitle style, handlers,
/// volume, layout, ...) is remembered and replayed on an engine that is activated later.
final class PlayerEngineRouterBridge: NSObject, NuvioPlayerBridge {

    private enum ActiveEngine {
        case aether
        case mpv
    }

    private struct LoadArguments {
        let videoUrl: String
        let audioUrl: String?
        let headersJson: String?
        let subtitlesJson: String?
    }

    private let container = PlayerEngineContainerViewController()
    private var preferredEngine: PlayerEngineChoice = .mpv
    private var active: NuvioPlayerBridge?
    private var activeEngine: ActiveEngine?

    private var lastLoad: LoadArguments?
    /// Kept for a next-episode prepare, which applies them at load time.
    private var audioLanguages: [String]?
    private var wantsPlay: Bool?
    private var lastSeekTargetMs: Int64?
    /// Position to restore on mpv after a fallback, applied once mpv has loaded the stream.
    private var fallbackResumeMs: Int64?

    private var stickyKeys: [String] = []
    private var sticky: [String: (NuvioPlayerBridge) -> Void] = [:]

    /// Remembers a configuration call for engines activated later and forwards it to the active one.
    private func remember(_ key: String, _ apply: @escaping (NuvioPlayerBridge) -> Void) {
        if sticky[key] == nil { stickyKeys.append(key) }
        sticky[key] = apply
        if let active { apply(active) }
    }

    private func forget(_ key: String) {
        sticky[key] = nil
        stickyKeys.removeAll { $0 == key }
    }

    // MARK: - Engine selection

    func createPlayerViewController() -> UIViewController { container }

    func setPreferredEngine(engine: String) {
        preferredEngine = PlayerEngineChoice(rawValue: engine) ?? .mpv
    }

    func setLimitSourceRequests(enabled: Bool) {
        AetherPlayerBridgeImpl.setLimitsSourceRequests(enabled)
    }

    func loadFile(url: String) {
        loadFileWithAudio(videoUrl: url, audioUrl: nil, headersJson: nil, subtitlesJson: nil)
    }

    func loadFileWithAudio(videoUrl: String, audioUrl: String?, headersJson: String?, subtitlesJson: String?) {
        let load = LoadArguments(videoUrl: videoUrl, audioUrl: audioUrl, headersJson: headersJson, subtitlesJson: subtitlesJson)
        lastLoad = load
        lastSeekTargetMs = nil
        fallbackResumeMs = nil

        let engine: ActiveEngine
        switch preferredEngine {
        case .mpv: engine = .mpv
        case .aether: engine = .aether
        case .auto: engine = AetherPlayerBridgeImpl.canAttempt(audioUrl: audioUrl) ? .aether : .mpv
        }
        print("[PlayerEngineRouter] preferred=\(preferredEngine.rawValue) using=\(engine)")
        let prepared = PreparedAetherPlayer.shared
        if prepared.hasPrepared, active == nil {
            if engine == .aether, let adopted = prepared.take(matching: PreparedAetherPlayer.Arguments(
                videoUrl: videoUrl,
                headersJson: headersJson,
                subtitlesJson: subtitlesJson
            )) {
                // The next episode is already loaded and paused; Kotlin's play() starts it.
                activate(.aether, adopting: adopted)
                adopted.didAdopt()
                return
            }
            prepared.discard(reason: "next load runs on \(engine)")
        }
        activate(engine)
        active?.loadFileWithAudio(
            videoUrl: load.videoUrl,
            audioUrl: load.audioUrl,
            headersJson: load.headersJson,
            subtitlesJson: load.subtitlesJson
        )
    }

    private func activate(
        _ engine: ActiveEngine,
        deferTeardownOfPrevious: Bool = false,
        adopting adopted: AetherPlayerBridgeImpl? = nil
    ) {
        guard activeEngine != engine else { return }
        if let previous = active {
            container.removeEngineController()
            if deferTeardownOfPrevious {
                // The previous engine is reporting its failure from inside its own callbacks.
                DispatchQueue.main.async { previous.destroy() }
            } else {
                previous.destroy()
            }
        }

        let bridge: NuvioPlayerBridge
        switch engine {
        case .aether:
            let aether = adopted ?? AetherPlayerBridgeImpl()
            aether.onLoadFailed = { [weak self] message in self?.handleAetherLoadFailure(message) }
            bridge = aether
        case .mpv:
            bridge = MPVPlayerBridgeImpl()
        }
        active = bridge
        activeEngine = engine
        container.show(bridge.createPlayerViewController())
        for key in stickyKeys { sticky[key]?(bridge) }
    }

    private func handleAetherLoadFailure(_ message: String) {
        guard preferredEngine == .auto, activeEngine == .aether, let lastLoad else { return }
        print("[PlayerEngineRouter] AetherEngine could not play the stream (\(message)); falling back to mpv")
        // The outgoing engine would keep the audio session for a prepared one; mpv takes over instead.
        PreparedAetherPlayer.shared.discard(reason: "engine fell back to mpv")

        // Kotlin applies its resume seek once, as soon as the player stops loading; if that already
        // happened on AetherEngine, carry the position over to mpv.
        let aetherPositionMs = active?.getPositionMs() ?? 0
        let resumeMs = max(lastSeekTargetMs ?? 0, aetherPositionMs)
        fallbackResumeMs = resumeMs > 0 ? resumeMs : nil

        // Switch synchronously so Kotlin's next poll already sees mpv loading, never AetherEngine's error.
        activate(.mpv, deferTeardownOfPrevious: true)
        active?.loadFileWithAudio(
            videoUrl: lastLoad.videoUrl,
            audioUrl: lastLoad.audioUrl,
            headersJson: lastLoad.headersJson,
            subtitlesJson: lastLoad.subtitlesJson
        )
        switch wantsPlay {
        case true?: active?.play()
        case false?: active?.pause()
        case nil: break
        }
    }

    // MARK: - Next-episode prepare

    /// Loads the next episode paused on a second AetherEngine. Only while this router plays on
    /// AetherEngine and the stream is one AetherEngine can take; mpv keeps today's behavior.
    func prepareNextFile(
        videoUrl: String,
        audioUrl: String?,
        headersJson: String?,
        subtitlesJson: String?,
        startPositionMs: Int64,
        debugLogging: Bool
    ) -> Bool {
        guard activeEngine == .aether, preferredEngine != .mpv,
              AetherPlayerBridgeImpl.canAttempt(audioUrl: audioUrl) else {
            if debugLogging {
                print("[NextEp][aether] prepare skipped: engine=\(String(describing: activeEngine)) preferred=\(preferredEngine.rawValue)")
            }
            return false
        }
        PreparedAetherPlayer.shared.prepare(
            PreparedAetherPlayer.Arguments(videoUrl: videoUrl, headersJson: headersJson, subtitlesJson: subtitlesJson),
            startPositionMs: startPositionMs,
            audioLanguages: audioLanguages,
            debugLogging: debugLogging
        )
        return true
    }

    func discardPreparedNextFile() {
        PreparedAetherPlayer.shared.discard(reason: "discarded by the player")
    }

    // MARK: - Transport

    func play() {
        wantsPlay = true
        active?.play()
    }

    func pause() {
        wantsPlay = false
        active?.pause()
    }

    func seekTo(positionMs: Int64) {
        lastSeekTargetMs = positionMs
        active?.seekTo(positionMs: positionMs)
    }

    func seekBy(offsetMs: Int64) { active?.seekBy(offsetMs: offsetMs) }
    func retry() { active?.retry() }

    // MARK: - Remembered configuration

    func setSystemControlHandler(handler: PlayerSystemControlHandler?) {
        remember("systemControlHandler") { $0.setSystemControlHandler(handler: handler) }
    }
    func setVideoZoom(scale: Double) {
        remember("videoZoom") { $0.setVideoZoom(scale: scale) }
    }
    func setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: Bool) {
        remember("singlePrimaryPiP") { $0.setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: enabled) }
    }
    func updateNowPlayingMetadata(title: String, subtitle: String?, artworkUrl: String?) {
        remember("nowPlaying") { $0.updateNowPlayingMetadata(title: title, subtitle: subtitle, artworkUrl: artworkUrl) }
    }
    func clearNowPlayingInfo() {
        forget("nowPlaying")
        active?.clearNowPlayingInfo()
    }
    func setKeyboardShortcutsEnabled(enabled: Bool) {
        remember("keyboardShortcutsEnabled") { $0.setKeyboardShortcutsEnabled(enabled: enabled) }
    }
    func setKeyboardShortcutHandler(handler: ((String) -> Void)?) {
        remember("keyboardShortcutHandler") { $0.setKeyboardShortcutHandler(handler: handler) }
    }
    func configureVideoOutput(
        hardwareDecoder: String,
        targetColorspaceHint: Bool,
        toneMapping: String,
        hdrComputePeak: Bool,
        targetPrimaries: String,
        targetTransfer: String,
        extendedDynamicRange: Bool,
        deband: Bool,
        interpolation: Bool,
        brightness: Int32,
        contrast: Int32,
        saturation: Int32,
        gamma: Int32
    ) {
        remember("videoOutput") {
            $0.configureVideoOutput(
                hardwareDecoder: hardwareDecoder,
                targetColorspaceHint: targetColorspaceHint,
                toneMapping: toneMapping,
                hdrComputePeak: hdrComputePeak,
                targetPrimaries: targetPrimaries,
                targetTransfer: targetTransfer,
                extendedDynamicRange: extendedDynamicRange,
                deband: deband,
                interpolation: interpolation,
                brightness: brightness,
                contrast: contrast,
                saturation: saturation,
                gamma: gamma
            )
        }
    }
    func configureAudioOutput(audioOutput: String) {
        remember("audioOutput") { $0.configureAudioOutput(audioOutput: audioOutput) }
    }
    func applyAudioLanguagePreferences(languages: [String]) {
        audioLanguages = languages
        remember("audioLanguages") { $0.applyAudioLanguagePreferences(languages: languages) }
    }
    func setPlaybackSpeed(speed: Float) {
        remember("speed") { $0.setPlaybackSpeed(speed: speed) }
    }
    func setVolume(volume: Float) {
        remember("volume") { $0.setVolume(volume: volume) }
    }
    func setMuted(muted: Bool) {
        remember("muted") { $0.setMuted(muted: muted) }
    }
    func setEmbeddedPreviewMode(enabled: Bool) {
        remember("embeddedPreview") { $0.setEmbeddedPreviewMode(enabled: enabled) }
    }
    func setResizeMode(mode: Int32) {
        remember("resizeMode") { $0.setResizeMode(mode: mode) }
    }
    func syncVideoSurfaceLayout(width: Double, height: Double) {
        remember("surfaceLayout") { $0.syncVideoSurfaceLayout(width: width, height: height) }
    }
    func setSubtitleUrl(url: String) {
        remember("subtitleUrl") { $0.setSubtitleUrl(url: url) }
    }
    func clearExternalSubtitle() {
        forget("subtitleUrl")
        active?.clearExternalSubtitle()
    }
    func clearExternalSubtitleAndSelect(trackId: Int32) {
        forget("subtitleUrl")
        active?.clearExternalSubtitleAndSelect(trackId: trackId)
    }
    func setSubtitleDelayMs(delayMs: Int32) {
        remember("subtitleDelay") { $0.setSubtitleDelayMs(delayMs: delayMs) }
    }
    func setSubtitleFontPath(path: String) {
        remember("subtitleFont") { $0.setSubtitleFontPath(path: path) }
    }
    func applySubtitleStyle(
        textColor: String,
        backgroundColor: String,
        outlineColor: String,
        outlineSize: Float,
        shadowOffset: Float,
        bold: Bool,
        fontSize: Float,
        subPos: Int32,
        stripSdh: Bool
    ) {
        remember("subtitleStyle") {
            $0.applySubtitleStyle(
                textColor: textColor,
                backgroundColor: backgroundColor,
                outlineColor: outlineColor,
                outlineSize: outlineSize,
                shadowOffset: shadowOffset,
                bold: bold,
                fontSize: fontSize,
                subPos: subPos,
                stripSdh: stripSdh
            )
        }
    }

    // MARK: - Pass-through

    func getKeepsPlaybackInBackground() -> Bool { active?.getKeepsPlaybackInBackground() ?? false }
    func isPictureInPictureSupported() -> Bool { active?.isPictureInPictureSupported() ?? false }
    func startPictureInPicture() { active?.startPictureInPicture() }
    func getVolume() -> Float { active?.getVolume() ?? 1.0 }

    // Track ids belong to one engine, so selections are not replayed across a fallback.
    func getAudioTrackCount() -> Int32 { active?.getAudioTrackCount() ?? 0 }
    func getAudioTrackIndex(at: Int32) -> Int32 { active?.getAudioTrackIndex(at: at) ?? 0 }
    func getAudioTrackId(at: Int32) -> String { active?.getAudioTrackId(at: at) ?? "0" }
    func getAudioTrackLabel(at: Int32) -> String { active?.getAudioTrackLabel(at: at) ?? "" }
    func getAudioTrackLang(at: Int32) -> String { active?.getAudioTrackLang(at: at) ?? "" }
    func isAudioTrackSelected(at: Int32) -> Bool { active?.isAudioTrackSelected(at: at) ?? false }
    func getSubtitleTrackCount() -> Int32 { active?.getSubtitleTrackCount() ?? 0 }
    func getSubtitleTrackIndex(at: Int32) -> Int32 { active?.getSubtitleTrackIndex(at: at) ?? 0 }
    func getSubtitleTrackId(at: Int32) -> String { active?.getSubtitleTrackId(at: at) ?? "0" }
    func getSubtitleTrackLabel(at: Int32) -> String { active?.getSubtitleTrackLabel(at: at) ?? "" }
    func getSubtitleTrackLang(at: Int32) -> String { active?.getSubtitleTrackLang(at: at) ?? "" }
    func isSubtitleTrackSelected(at: Int32) -> Bool { active?.isSubtitleTrackSelected(at: at) ?? false }
    func selectAudioTrack(trackId: Int32) { active?.selectAudioTrack(trackId: trackId) }
    func selectSubtitleTrack(trackId: Int32) { active?.selectSubtitleTrack(trackId: trackId) }

    func getIsLoading() -> Bool {
        guard let active else { return true }
        let loading = active.getIsLoading()
        if !loading, let resumeMs = fallbackResumeMs, activeEngine == .mpv, active.getDurationMs() > 0 {
            fallbackResumeMs = nil
            active.seekTo(positionMs: resumeMs)
        }
        return loading
    }
    func getIsPlaying() -> Bool { active?.getIsPlaying() ?? false }
    func getIsEnded() -> Bool { active?.getIsEnded() ?? false }
    func getDurationMs() -> Int64 { active?.getDurationMs() ?? 0 }
    func getPositionMs() -> Int64 { active?.getPositionMs() ?? 0 }
    func getBufferedMs() -> Int64 { active?.getBufferedMs() ?? 0 }
    func getPlaybackSpeed() -> Float { active?.getPlaybackSpeed() ?? 1.0 }
    func getVideoWidth() -> Int32 { active?.getVideoWidth() ?? 0 }
    func getVideoHeight() -> Int32 { active?.getVideoHeight() ?? 0 }
    func getErrorMessage() -> String { active?.getErrorMessage() ?? "" }
    func getMediaInfoJson() -> String { active?.getMediaInfoJson() ?? "{}" }
    func getProperty(name: String) -> String { active?.getProperty(name: name) ?? "" }

    func destroy() {
        active?.destroy()
        active = nil
        activeEngine = nil
        container.removeEngineController()
        sticky.removeAll()
        stickyKeys.removeAll()
    }
}

// MARK: - Container

/// The view controller Compose hosts. Holds the active engine's view controller as a child so the
/// engine can change (AetherEngine to mpv fallback) without Compose re-creating the interop view.
final class PlayerEngineContainerViewController: UIViewController {

    private var engineController: UIViewController?

    override func loadView() {
        let container = UIView()
        container.backgroundColor = .black
        view = container
    }

    func show(_ controller: UIViewController) {
        guard engineController !== controller else { return }
        removeEngineController()
        loadViewIfNeeded()
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        engineController = controller
        refreshSystemUIForwarding()
    }

    func removeEngineController() {
        guard let controller = engineController else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        engineController = nil
        refreshSystemUIForwarding()
    }

    private func refreshSystemUIForwarding() {
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    override var childForStatusBarHidden: UIViewController? { engineController }
    override var childForStatusBarStyle: UIViewController? { engineController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { engineController }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { engineController }
}

// MARK: - Bridge Creator / Registration

final class PlayerEngineRouterCreator: NSObject, NuvioPlayerBridgeCreator {
    func createBridge() -> any NuvioPlayerBridge {
        return PlayerEngineRouterBridge()
    }
}

enum PlayerEngineRouterRegistration {
    /// Call after NuvioPlayerRegistration.register(): replaces the mpv-only bridge factory.
    static func register() {
        NuvioPlayerBridgeFactory.shared.registerFactory(creator: PlayerEngineRouterCreator())
    }
}
