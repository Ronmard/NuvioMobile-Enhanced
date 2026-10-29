import UIKit
import NuvioAetherKit

/// How the Aether subtitle overlay draws text. Sizes are in mpv's units (pixels at a 720 px tall
/// window, scaled with the window) so the values Kotlin sends for mpv look the same here.
struct AetherSubtitleStyle: Equatable {
    var textColor: UIColor = .white
    /// nil draws outline-and-shadow; a colour draws an opaque box behind the text.
    var backgroundColor: UIColor?
    var outlineColor: UIColor = .black
    var outlineSize: CGFloat = 2
    var shadowColor: UIColor = UIColor(white: 0, alpha: 0xB3 / 255.0)
    var shadowOffset: CGFloat = 0
    var bold = false
    /// mpv `sub-font-size`: height of a text line, not the em size.
    var fontSize: CGFloat = 54
    /// mpv `sub-pos`: 100 is the default bottom position, lower values move the text up.
    var subPos: CGFloat = 100
    var fontFamily: String?
    /// Remove hearing-impaired annotations (mpv `sub-filter-sdh`).
    var stripSdh = false
}

/// Draws the active text cues of the selected AetherEngine subtitle track over the video.
///
/// Cues are timed on the engine's source axis; the clock it publishes ticks at ~10 Hz, so the overlay
/// interpolates between ticks while playing to switch cues on the frame they are due.
final class AetherSubtitleOverlayView: UIView {

    struct Clock {
        let seconds: Double
        let isRunning: Bool
        let rate: Double
    }

    /// mpv's default `sub-margin-y` / `sub-margin-x`, in 720p-scaled pixels.
    private static let verticalMargin: CGFloat = 22
    private static let horizontalMargin: CGFloat = 25
    /// Never extrapolate further than this past the last clock tick (a stalled clock must not run on).
    private static let maxExtrapolationSeconds: Double = 0.25

    var clock: (() -> Clock?)?

    var cues: [NuvioAetherSubtitleCue] = [] {
        didSet {
            updateDisplayLink()
            refreshActiveCues()
        }
    }

    var style = AetherSubtitleStyle() {
        didSet {
            guard style != oldValue else { return }
            if style.stripSdh != oldValue.stripSdh { refreshActiveCues(force: true) }
            setNeedsDisplay()
        }
    }

    /// mpv `sub-delay`: positive shows subtitles later.
    var delaySeconds: Double = 0 {
        didSet { if delaySeconds != oldValue { refreshActiveCues() } }
    }

    private var bottomText = ""
    private var topText = ""
    private var displayLink: CADisplayLink?
    private var anchorClockSeconds: Double = .nan
    private var anchorHostTime: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    func reset() {
        cues = []
        anchorClockSeconds = .nan
    }

    // MARK: - Timing

    private func updateDisplayLink() {
        let wantsTicks = window != nil && !cues.isEmpty
        if wantsTicks, displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wantsTicks, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    fileprivate func tick() {
        refreshActiveCues()
    }

    private func currentTime() -> Double? {
        guard let clock = clock?() else { return nil }
        let now = CACurrentMediaTime()
        if clock.seconds != anchorClockSeconds {
            anchorClockSeconds = clock.seconds
            anchorHostTime = now
        }
        guard clock.isRunning else { return clock.seconds }
        let elapsed = min(now - anchorHostTime, Self.maxExtrapolationSeconds)
        return clock.seconds + elapsed * clock.rate
    }

    private func refreshActiveCues(force: Bool = false) {
        var top: [String] = []
        var bottom: [String] = []
        if !cues.isEmpty, let playbackTime = currentTime() {
            let time = playbackTime - delaySeconds
            let active = cues
                .filter { $0.startSeconds <= time && time < $0.endSeconds }
                .sorted { $0.startSeconds < $1.startSeconds }
            for cue in active {
                let text = style.stripSdh ? AetherSubtitleSdhFilter.strip(cue.text) : cue.text
                guard !text.isEmpty else { continue }
                if let alignment = cue.alignment, (7...9).contains(alignment) {
                    top.append(text)
                } else {
                    bottom.append(text)
                }
            }
        }
        let newTop = top.joined(separator: "\n")
        let newBottom = bottom.joined(separator: "\n")
        guard force || newTop != topText || newBottom != bottomText else { return }
        topText = newTop
        bottomText = newBottom
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard bounds.height > 0, !(topText.isEmpty && bottomText.isEmpty),
              let context = UIGraphicsGetCurrentContext() else { return }
        let scale = bounds.height / 720
        let font = Self.font(style: style, scale: scale)
        let margin = Self.verticalMargin * scale

        if !bottomText.isEmpty {
            let bottomY = min(bounds.height * style.subPos / 100 - margin, bounds.height - margin)
            drawBlock(bottomText, font: font, scale: scale, in: context) { size in
                max(bottomY - size.height, margin)
            }
        }
        if !topText.isEmpty {
            drawBlock(topText, font: font, scale: scale, in: context) { _ in margin }
        }
    }

    private func drawBlock(
        _ text: String,
        font: UIFont,
        scale: CGFloat,
        in context: CGContext,
        top: (CGSize) -> CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let maxWidth = max(bounds.width - 2 * Self.horizontalMargin * scale, 1)
        let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor,
            .paragraphStyle: paragraph,
        ]
        let fill = NSAttributedString(string: text, attributes: fillAttributes)
        let textSize = fill.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).integral.size
        let textRect = CGRect(
            x: (bounds.width - maxWidth) / 2,
            y: top(textSize),
            width: maxWidth,
            height: textSize.height
        )

        let outline = style.outlineSize * scale
        if let background = style.backgroundColor {
            let padding = max(outline, scale)
            let box = CGRect(
                x: bounds.midX - textSize.width / 2 - padding,
                y: textRect.minY - padding,
                width: textSize.width + 2 * padding,
                height: textSize.height + 2 * padding
            )
            context.setFillColor(background.cgColor)
            context.fill(box)
            fill.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            return
        }

        let shadow = style.shadowOffset * scale
        context.saveGState()
        if shadow > 0 {
            context.setShadow(offset: CGSize(width: shadow, height: shadow), blur: 0, color: style.shadowColor.cgColor)
        }
        // One transparency layer so the shadow falls from the outlined glyph as a whole.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if outline > 0 {
            var strokeAttributes = fillAttributes
            // Positive stroke width = stroke only, in percent of the point size; the stroke is
            // centred on the glyph path, so twice the outline leaves `outline` outside the glyph.
            strokeAttributes[.strokeWidth] = 2 * outline / font.pointSize * 100
            strokeAttributes[.strokeColor] = style.outlineColor
            context.setLineJoin(.round)
            NSAttributedString(string: text, attributes: strokeAttributes)
                .draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        fill.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// mpv sizes a line by its height (ascender + descender); UIFont sizes by em, so convert.
    private static func font(style: AetherSubtitleStyle, scale: CGFloat) -> UIFont {
        let lineHeight = max(style.fontSize * scale, 1)
        let base: UIFont
        let named = style.fontFamily.map { UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: $0]), size: 100) }
        if let named, named.familyName == style.fontFamily {
            base = named
        } else {
            base = UIFont.systemFont(ofSize: 100, weight: .medium)
        }
        var font = base
        if style.bold, let bold = base.fontDescriptor.withSymbolicTraits(.traitBold) {
            font = UIFont(descriptor: bold, size: 100)
        }
        let ratio = (font.ascender - font.descender) / 100
        return font.withSize(lineHeight / max(ratio, 0.5))
    }
}

/// Keeps CADisplayLink from retaining the overlay.
private final class DisplayLinkProxy: NSObject {
    weak var target: AetherSubtitleOverlayView?
    init(_ target: AetherSubtitleOverlayView) { self.target = target }
    @objc func tick() { target?.tick() }
}
