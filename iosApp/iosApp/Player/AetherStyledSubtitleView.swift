import AVFoundation
import UIKit
import NuvioAetherKit

/// Draws authored subtitles over the AetherEngine picture: styled ASS/SSA through libass, laid out in
/// the on-screen video rect and kept in step with playback.
///
/// Sits between the video surface and `AetherSubtitleOverlayView`; the overlay keeps drawing every
/// cue this view does not (`isRenderingASS` says which).
final class AetherStyledSubtitleView: UIView {

    struct VideoGeometry {
        /// Picture shape as presented (coded size under the pixel aspect).
        let displaySize: CGSize
        /// Coded size, the frame libass treats as the script's storage.
        let codedSize: CGSize
    }

    var clock: (() -> AetherSubtitleOverlayView.Clock?)?
    var videoGeometry: (() -> VideoGeometry?)?

    /// 0 = Fit, 1 = Fill (stretch), 2 = Zoom (crop), as the bridge's resize modes.
    var resizeMode = 0 {
        didSet { if resizeMode != oldValue { requestRender() } }
    }
    /// The zoom transform applied to the video surface.
    var videoZoom: CGFloat = 1 {
        didSet { if videoZoom != oldValue { requestRender() } }
    }
    /// mpv `sub-delay`: positive shows subtitles later.
    var delaySeconds: Double = 0 {
        didSet { if delaySeconds != oldValue { requestRender() } }
    }
    /// mpv `sub-font`: the family text falls back to when a style's font is missing.
    var defaultFontFamily: String? {
        didSet { if defaultFontFamily != oldValue { renderer?.setDefaultFamily(defaultFontFamily) } }
    }

    /// True while libass draws the selected track; its raw-event cues are then this view's.
    private(set) var isRenderingASS = false

    private let contentLayer = CALayer()
    private var renderer: AetherASSRenderer?
    private var didFailToCreateRenderer = false
    private var displayLink: CADisplayLink?
    private var clockInterpolator = AetherSubtitleClockInterpolator()
    /// Bumped whenever the track or its events change, so the next tick renders again even at the same
    /// time and size.
    private var contentGeneration = 0
    /// Bumped when the source changes: a render in flight for the previous track is dropped.
    private var sourceGeneration = 0
    private var isRenderInFlight = false
    private var lastRequest: RenderRequest?
    /// The image on screen, in pixels of the frame it was rendered for, and that frame's size.
    private var shownPixelRect: CGRect = .null
    private var shownPixelSize: CGSize = .zero

    private struct RenderRequest: Equatable {
        let timeMs: Int64
        let videoRect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let generation: Int
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        contentLayer.contentsGravity = .resize
        layer.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        requestRender()
    }

    // MARK: - Content

    /// The selected track's ASS source; nil when the track is not styled ASS (or nothing is selected).
    /// `fonts` are the media's attached fonts, used only when a source is set.
    func setASSSource(_ source: NuvioAetherASSSource?, fonts: @autoclosure () -> [NuvioAetherFontAttachment]) {
        if source != nil, renderer == nil, !didFailToCreateRenderer {
            renderer = AetherASSRenderer()
            didFailToCreateRenderer = renderer == nil
            if didFailToCreateRenderer {
                print("[AetherSubtitles] libass could not be initialised; styled ASS falls back to plain text")
            }
            renderer?.setDefaultFamily(defaultFontFamily)
        }
        guard let renderer else {
            isRenderingASS = false
            return
        }
        renderer.setSource(source, fonts: source == nil ? [] : fonts())
        isRenderingASS = source != nil
        contentGeneration += 1
        sourceGeneration += 1
        if source == nil { clearContent() }
        renderer.addEvents(from: cues)
        updateDisplayLink()
        requestRender()
    }

    /// The selected track's cues; only those carrying raw ASS events are drawn here.
    var cues: [NuvioAetherSubtitleCue] = [] {
        didSet {
            guard isRenderingASS, let renderer else { return }
            if cues.isEmpty {
                renderer.flushEvents()
            } else {
                renderer.addEvents(from: cues)
            }
            contentGeneration += 1
            requestRender()
        }
    }

    func reset() {
        cues = []
        clockInterpolator.reset()
        clearContent()
    }

    private func clearContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = nil
        CATransaction.commit()
        shownPixelRect = .null
        lastRequest = nil
    }

    // MARK: - Timing

    private func updateDisplayLink() {
        let wantsTicks = window != nil && isRenderingASS
        if wantsTicks, displayLink == nil {
            let link = CADisplayLink(target: StyledSubtitleDisplayLinkProxy(self), selector: #selector(StyledSubtitleDisplayLinkProxy.tick))
            // Moves, fades and karaoke sweeps animate per frame.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wantsTicks, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    fileprivate func tick() {
        requestRender()
    }

    // MARK: - Rendering

    private func requestRender() {
        guard isRenderingASS, let renderer, !isRenderInFlight else { return }
        guard let geometry = videoGeometry?(), let clock = clock?(), bounds.width > 0, bounds.height > 0 else {
            clearContent()
            return
        }
        let rect = Self.videoRect(displaySize: geometry.displaySize, in: bounds, resizeMode: resizeMode, zoom: videoZoom)
        guard rect.width >= 1, rect.height >= 1 else { return }
        let scale = window?.screen.scale ?? contentScaleFactor
        let width = Int((rect.width * scale).rounded())
        let height = Int((rect.height * scale).rounded())
        let time = clockInterpolator.time(for: clock) - delaySeconds
        let timeMs = Int64((time * 1000).rounded())

        let request = RenderRequest(timeMs: timeMs, videoRect: rect, pixelWidth: width, pixelHeight: height, generation: contentGeneration)
        // Paused with nothing new: libass would answer "unchanged" anyway.
        guard request != lastRequest else { return }
        lastRequest = request
        isRenderInFlight = true
        let generation = sourceGeneration
        renderer.render(timeMs: timeMs, width: width, height: height, storage: geometry.codedSize) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRenderInFlight = false
                // A newer content generation is fine: the frame is still right for its time and the next
                // tick renders the new events. Only another track's frame must not be shown.
                guard generation == self.sourceGeneration, self.isRenderingASS else { return }
                self.apply(result, videoRect: rect, pixelSize: CGSize(width: width, height: height))
            }
        }
    }

    private func apply(_ result: AetherASSRenderer.Result, videoRect: CGRect, pixelSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch result {
        case .unchanged:
            // Same image; it still follows the video rect if only the layout moved.
            break
        case .frame(let image, let pixelRect):
            contentLayer.contents = image
            shownPixelRect = image == nil ? .null : pixelRect
            shownPixelSize = pixelSize
        }
        guard !shownPixelRect.isNull, shownPixelSize.width > 0, shownPixelSize.height > 0 else { return }
        let scaleX = videoRect.width / shownPixelSize.width
        let scaleY = videoRect.height / shownPixelSize.height
        contentLayer.frame = CGRect(
            x: videoRect.minX + shownPixelRect.minX * scaleX,
            y: videoRect.minY + shownPixelRect.minY * scaleY,
            width: shownPixelRect.width * scaleX,
            height: shownPixelRect.height * scaleY
        )
    }

    /// Where the video surface draws the picture: its gravity applied to `bounds`, then the zoom
    /// transform about the centre.
    static func videoRect(displaySize: CGSize, in bounds: CGRect, resizeMode: Int, zoom: CGFloat) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }
        var rect: CGRect
        switch resizeMode {
        case 1:
            rect = bounds
        case 2:
            let scale = max(bounds.width / displaySize.width, bounds.height / displaySize.height)
            let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
            rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        default:
            rect = AVMakeRect(aspectRatio: displaySize, insideRect: bounds)
        }
        guard zoom != 1 else { return rect }
        let size = CGSize(width: rect.width * zoom, height: rect.height * zoom)
        let center = CGPoint(
            x: bounds.midX + (rect.midX - bounds.midX) * zoom,
            y: bounds.midY + (rect.midY - bounds.midY) * zoom
        )
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Keeps CADisplayLink from retaining the view.
private final class StyledSubtitleDisplayLinkProxy: NSObject {
    weak var target: AetherStyledSubtitleView?
    init(_ target: AetherStyledSubtitleView) { self.target = target }
    @objc func tick() { target?.tick() }
}
