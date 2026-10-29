import UIKit

extension AetherSubtitleStyle {
    /// Builds the overlay style from the values Kotlin sends through `applySubtitleStyle`, resolved the
    /// same way `MPVPlayerViewController.applySubtitleStyle` maps them onto mpv options.
    init(
        mpvTextColor textColor: String,
        backgroundColor: String,
        outlineColor: String,
        outlineSize: Float,
        shadowOffset: Float,
        bold: Bool,
        fontSize: Float,
        subPos: Int32,
        fontFamily: String?
    ) {
        self.init()
        let hasBackground = !backgroundColor.hasPrefix("#00")
        self.textColor = Self.color(mpv: textColor) ?? .white
        self.backgroundColor = hasBackground ? Self.color(mpv: backgroundColor) : nil
        self.outlineColor = Self.color(mpv: outlineColor) ?? .black
        // An opaque box pads the text by the outline size (at least 1), as mpv's opaque-box does.
        self.outlineSize = CGFloat(hasBackground ? max(outlineSize, 1) : outlineSize)
        self.shadowOffset = hasBackground ? 0 : CGFloat(shadowOffset)
        self.bold = bold
        self.fontSize = CGFloat(fontSize)
        self.subPos = CGFloat(min(max(subPos, 0), 150))
        self.fontFamily = fontFamily
    }

    /// mpv colour strings as Kotlin sends them: "#AARRGGBB" (or "#RRGGBB").
    static func color(mpv value: String) -> UIColor? {
        var hex = value.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 6 { hex = "FF" + hex }
        guard hex.count == 8, let argb = UInt32(hex, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255
        )
    }
}

/// Removes hearing-impaired annotations, approximating mpv's `sub-filter-sdh` plus
/// `sub-filter-sdh-harder` (both of which the mpv path turns on together).
enum AetherSubtitleSdhFilter {
    /// [door slams], (laughs); may span lines.
    private static let annotation = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\([^)]*\)"#)
    /// "JOHN:", "Man #2:", "Mrs. Smith:" at the start of a line, keeping a dialogue dash.
    private static let speaker = try! NSRegularExpression(
        pattern: #"^(\s*[-–—]?\s*)[\p{Lu}0-9][\p{L}0-9 .'’#&-]{0,30}:\s+"#,
        options: [.anchorsMatchLines]
    )

    static func strip(_ text: String) -> String {
        var result = replace(annotation, in: text, with: "")
        result = replace(speaker, in: result, with: "$1")
        return result
            .components(separatedBy: "\n")
            .map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
            .filter { line in
                // A line left with nothing but a dialogue dash or punctuation was all annotation.
                line.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || $0 == "♪" }
            }
            .joined(separator: "\n")
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
