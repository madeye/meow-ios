import SwiftUI
import UIKit

// MARK: - SwiftUI bridge

struct ClashYAMLTextView: UIViewRepresentable {
    @Binding var text: String
    var errorLines: Set<Int>

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> GutteredTextView {
        let view = GutteredTextView()
        view.textView.delegate = context.coordinator
        view.textView.text = text
        view.errorLines = errorLines
        view.applyHighlighting()
        return view
    }

    func updateUIView(_ view: GutteredTextView, context _: Context) {
        if view.textView.text != text {
            view.textView.text = text
            view.applyHighlighting()
        }
        if view.errorLines != errorLines {
            view.errorLines = errorLines
            view.applyErrorHighlighting()
            view.syncGutterScroll()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ClashYAMLTextView
        init(_ parent: ClashYAMLTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if let gutteredView = textView.superview as? GutteredTextView {
                gutteredView.applyHighlighting()
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if let gutteredView = scrollView.superview as? GutteredTextView {
                gutteredView.syncGutterScroll()
            }
        }
    }
}

// MARK: - Gutter + editor container

final class GutteredTextView: UIView {
    let textView = UITextView()
    let gutterView = GutterView()
    var errorLines: Set<Int> = []

    private static let gutterWidth: CGFloat = 44
    private static let monoFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setup() {
        textView.font = Self.monoFont
        textView.adjustsFontForContentSizeCategory = true
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.alwaysBounceVertical = true

        gutterView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.5)

        addSubview(gutterView)
        addSubview(textView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gw = Self.gutterWidth
        gutterView.frame = CGRect(x: 0, y: 0, width: gw, height: bounds.height)
        textView.frame = CGRect(x: gw, y: 0, width: bounds.width - gw, height: bounds.height)
        syncGutterScroll()
    }

    func syncGutterScroll() {
        gutterView.lineInfo = computeLineInfo()
        gutterView.setNeedsDisplay()
    }

    func applyHighlighting() {
        YAMLHighlighter.highlight(textView.textStorage, font: Self.monoFont)
        applyErrorHighlighting()
        syncGutterScroll()
    }

    func applyErrorHighlighting() {
        let storage = textView.textStorage
        let nsText = storage.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: fullRange)
        guard !errorLines.isEmpty else {
            storage.endEditing()
            return
        }
        let errorBg = UIColor.systemRed.withAlphaComponent(0.12)
        var charIdx = 0
        var lineNumber = 1
        while charIdx < nsText.length {
            let nlRange = nsText.range(
                of: "\n",
                range: NSRange(location: charIdx, length: nsText.length - charIdx),
            )
            let lineEnd = nlRange.location == NSNotFound ? nsText.length : NSMaxRange(nlRange)
            if errorLines.contains(lineNumber) {
                storage.addAttribute(
                    .backgroundColor,
                    value: errorBg,
                    range: NSRange(location: charIdx, length: lineEnd - charIdx),
                )
            }
            if nlRange.location == NSNotFound { break }
            charIdx = NSMaxRange(nlRange)
            lineNumber += 1
        }
        storage.endEditing()
    }

    private func computeLineInfo() -> [GutterView.LineInfo] {
        let layoutManager = textView.layoutManager
        let text = textView.text ?? ""
        let nsText = text as NSString
        let contentOffset = textView.contentOffset.y
        let insetTop = textView.textContainerInset.top
        let numberOfGlyphs = layoutManager.numberOfGlyphs
        var infos: [GutterView.LineInfo] = []

        guard numberOfGlyphs > 0 else { return infos }

        var charIdx = 0
        var lineNumber = 1
        let textLength = nsText.length

        while charIdx < textLength {
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: charIdx)
            guard glyphIdx < numberOfGlyphs else { break }
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIdx,
                effectiveRange: nil,
            )
            let y = lineRect.origin.y + insetTop - contentOffset
            infos.append(GutterView.LineInfo(
                number: lineNumber,
                y: y,
                height: lineRect.height,
                hasError: errorLines.contains(lineNumber),
            ))
            let nlRange = nsText.range(
                of: "\n",
                range: NSRange(location: charIdx, length: textLength - charIdx),
            )
            if nlRange.location == NSNotFound { break }
            charIdx = NSMaxRange(nlRange)
            lineNumber += 1
        }
        return infos
    }
}

// MARK: - Gutter drawing

final class GutterView: UIView {
    struct LineInfo {
        let number: Int
        let y: CGFloat
        let height: CGFloat
        let hasError: Bool
    }

    var lineInfo: [LineInfo] = []

    private let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: UIColor.tertiaryLabel,
    ]

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setFillColor(UIColor.secondarySystemBackground.withAlphaComponent(0.5).cgColor)
        ctx?.fill(rect)

        for info in lineInfo {
            guard info.y + info.height > 0, info.y < rect.height else { continue }

            let numStr = "\(info.number)" as NSString
            let size = numStr.size(withAttributes: numberAttributes)
            let x = bounds.width - size.width - 8
            let y = info.y + (info.height - size.height) / 2
            numStr.draw(at: CGPoint(x: x, y: y), withAttributes: numberAttributes)

            if info.hasError {
                let dotSize: CGFloat = 6
                let dotX: CGFloat = 4
                let dotY = info.y + (info.height - dotSize) / 2
                UIColor.systemRed.setFill()
                UIBezierPath(ovalIn: CGRect(x: dotX, y: dotY, width: dotSize, height: dotSize)).fill()
            }
        }
    }
}

// MARK: - YAML syntax highlighter

// swiftlint:disable force_try
private let yamlComment = try! NSRegularExpression(pattern: #"#.*$"#, options: .anchorsMatchLines)
private let yamlKey = try! NSRegularExpression(pattern: #"^(\s*[\w][\w. -]*)(\s*:)"#, options: .anchorsMatchLines)
private let yamlStringDouble = try! NSRegularExpression(pattern: #""[^"\\]*(?:\\.[^"\\]*)*""#)
private let yamlStringSingle = try! NSRegularExpression(pattern: #"'[^'\\]*(?:\\.[^'\\]*)*'"#)
private let yamlNumber = try! NSRegularExpression(pattern: #"(?<=:\s)\d+(\.\d+)?\b"#)
private let yamlBoolNull = try! NSRegularExpression(
    pattern: #"(?<=:\s)\b(true|false|null|yes|no)\b"#,
    options: .caseInsensitive,
)
private let yamlListDash = try! NSRegularExpression(pattern: #"^\s*-\s"#, options: .anchorsMatchLines)
private let yamlClashSection = try! NSRegularExpression(
    pattern: [
        "^(proxies|proxy-groups|rules|dns|mixed-port",
        "|external-controller|allow-lan|ipv6|mode",
        "|log-level|tun|hosts|listeners|bind-address",
        "|sniffer|geox-url|profile):",
    ].joined(),
    options: .anchorsMatchLines,
)
// swiftlint:enable force_try

enum YAMLHighlighter {
    static func highlight(_ storage: NSTextStorage, font: UIFont) {
        let text = storage.string
        let range = NSRange(location: 0, length: (text as NSString).length)
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: isDark ? UIColor.white : UIColor.black,
        ], range: range)

        let keyColor = isDark ? UIColor.systemCyan : UIColor.systemBlue
        let strColor = isDark ? UIColor.systemGreen : UIColor(red: 0.77, green: 0.1, blue: 0.09, alpha: 1)
        let secColor = isDark ? UIColor.systemYellow : UIColor.systemPurple
        let boldFont = UIFont.monospacedSystemFont(
            ofSize: font.pointSize, weight: .bold,
        )

        apply(yamlClashSection, text: text, range: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: secColor, range: $0.range)
            storage.addAttribute(.font, value: boldFont, range: $0.range)
        }
        apply(yamlKey, text: text, range: range, storage: storage) {
            guard $0.numberOfRanges >= 3 else { return }
            storage.addAttribute(.foregroundColor, value: keyColor, range: $0.range(at: 1))
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: $0.range(at: 2))
        }
        apply(yamlListDash, text: text, range: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: $0.range)
        }
        apply(yamlStringDouble, text: text, range: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: strColor, range: $0.range)
        }
        apply(yamlStringSingle, text: text, range: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: strColor, range: $0.range)
        }
        apply(yamlNumber, text: text, range: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: $0.range)
        }
        apply(yamlBoolNull, text: text, range: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: $0.range)
        }
        apply(yamlComment, text: text, range: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: UIColor.systemGray, range: $0.range)
        }
        storage.endEditing()
    }

    private static func apply(
        _ regex: NSRegularExpression,
        text: String,
        range: NSRange,
        storage _: NSTextStorage,
        body: (NSTextCheckingResult) -> Void,
    ) {
        for match in regex.matches(in: text, range: range) {
            body(match)
        }
    }
}
