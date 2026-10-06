import AppKit

enum EditorFontStyle: String, CaseIterable, Identifiable {
    case mono, sans, serif
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mono: "Monospaced"
        case .sans: "System"
        case .serif: "Serif"
        }
    }
}

struct EditorTheme: Equatable {
    var style: EditorFontStyle
    var size: CGFloat

    func font(weight: NSFont.Weight = .regular, scale: CGFloat = 1) -> NSFont {
        let s = size * scale
        switch style {
        case .mono: return .monospacedSystemFont(ofSize: s, weight: weight)
        case .sans: return .systemFont(ofSize: s, weight: weight)
        case .serif:
            let base = NSFont.systemFont(ofSize: s, weight: weight)
            if let d = base.fontDescriptor.withDesign(.serif) { return NSFont(descriptor: d, size: s) ?? base }
            return base
        }
    }

    var codeFont: NSFont { .monospacedSystemFont(ofSize: size * (style == .mono ? 1 : 0.92), weight: .regular) }

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = style == .mono ? 1.32 : 1.4
        p.paragraphSpacing = 2
        return p
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font(), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle]
    }
}

enum Palette {
    static let marker = NSColor.tertiaryLabelColor
    static let muted = NSColor.secondaryLabelColor
    static let link = NSColor.linkColor
    static let accent = NSColor.controlAccentColor
    static let inlineCode = dynamic(light: (0.76, 0.18, 0.30), dark: (1.0, 0.54, 0.50))
    static let codeBlock = dynamic(light: (0.16, 0.42, 0.50), dark: (0.55, 0.82, 0.86))
    static let codeBackground = dynamic(light: (0.5, 0.5, 0.55), dark: (1, 1, 1), alphaLight: 0.08, alphaDark: 0.06)
    static let heading = NSColor.labelColor

    static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat),
                        alphaLight: CGFloat = 1, alphaDark: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: isDark ? alphaDark : alphaLight)
        }
    }
}

/// Regex-based Markdown syntax styling for the editor's text storage.
struct MarkdownHighlighter {
    let theme: EditorTheme

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let heading = rx(#"^( {0,3}#{1,6})([ \t]+.*)?$"#)
    private static let setextUnderline = rx(#"^ {0,3}(=+|-+)[ \t]*$"#)
    private static let quote = rx(#"^([ \t]*(?:>[ \t]?)+)(.*)$"#)
    private static let listMarker = rx(#"^[ \t]*(?:>[ \t]*)*([-*+]|\d+[.)])(?=[ \t])"#)
    private static let taskBox = rx(#"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+(\[[ xX]\])"#)
    private static let hr = rx(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let tablePipe = rx(#"^[ \t]*\|.*\|[ \t]*$"#)
    private static let inlineCode = rx(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#, [])
    private static let bold = rx(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, [])
    private static let italic = rx(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#, [])
    private static let strike = rx(#"(~~)(?=\S)(.+?)(?<=\S)~~"#, [])
    private static let highlight = rx(#"(==)(?=\S)(.+?)(?<=\S)=="#, [])
    private static let link = rx(#"(!?\[)((?:[^\[\]]|\[[^\]]*\])*)(\]\()([^)\s]*(?:\s+"[^"]*")?)(\))"#, [])
    private static let refLink = rx(#"^ {0,3}(\[[^\]]+\]:)[ \t]+(\S+.*)$"#)
    private static let autolink = rx(#"<(?:https?|mailto):[^>\s]+>|(?<![(\[<"])\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#, [])
    private static let html = rx(#"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>|<!--[\s\S]*?-->"#, [])
    private static let footnote = rx(#"\[\^[^\]]+\]"#, [])
    private static let math = rx(#"\$\$[\s\S]+?\$\$|(?<![\\$])\$(?!\s)[^$\n]+?(?<!\s)\$(?!\d)"#, [])
    private static let escape = rx(#"\\[\\`*_{}\[\]()#+\-.!|~<>$=]"#, [])

    func apply(to storage: NSTextStorage) {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(theme.baseAttributes, range: full)
        guard full.length > 0 else { return }

        var protected = IndexSet()  // code blocks, code spans, front matter
        var previousLine: (range: NSRange, text: String, inCode: Bool)?

        MarkdownScan.forEachLine(ns) { index, range, line, inCode in
            defer { previousLine = (range, line, inCode) }
            guard range.length > 0 || inCode else { return }
            if inCode {
                protected.insert(integersIn: Range(range) ?? 0..<0)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || (trimmed == "---" || trimmed == "...")
                storage.addAttributes([
                    .font: theme.codeFont,
                    .foregroundColor: isFence ? Palette.marker : Palette.codeBlock,
                ], range: range)
                return
            }
            let lineNS = line as NSString
            let local = NSRange(location: 0, length: lineNS.length)
            func abs(_ r: NSRange) -> NSRange { NSRange(location: range.location + r.location, length: r.length) }

            if let m = Self.heading.firstMatch(in: line, range: local) {
                let level = m.range(at: 1).length - (line.prefix(while: { $0 == " " }).count)
                let scale: [CGFloat] = [1.42, 1.26, 1.14, 1.06, 1.0, 1.0]
                storage.addAttributes([
                    .font: theme.font(weight: .bold, scale: scale[max(0, min(5, level - 1))]),
                    .foregroundColor: Palette.heading,
                ], range: range)
                storage.addAttribute(.foregroundColor, value: Palette.marker, range: abs(m.range(at: 1)))
                return
            }
            if let prev = previousLine, !prev.inCode, !prev.text.trimmingCharacters(in: .whitespaces).isEmpty,
               Self.setextUnderline.firstMatch(in: line, range: local) != nil,
               Self.listMarker.firstMatch(in: prev.text, range: NSRange(location: 0, length: (prev.text as NSString).length)) == nil {
                let isH1 = line.contains("=")
                storage.addAttributes([.font: theme.font(weight: .bold, scale: isH1 ? 1.42 : 1.26)], range: prev.range)
                storage.addAttribute(.foregroundColor, value: Palette.marker, range: range)
                return
            }
            if Self.hr.firstMatch(in: line, range: local) != nil {
                storage.addAttribute(.foregroundColor, value: Palette.marker, range: range)
                return
            }
            if let m = Self.quote.firstMatch(in: line, range: local) {
                storage.addAttribute(.foregroundColor, value: Palette.muted, range: range)
                storage.addAttribute(.foregroundColor, value: Palette.accent.withAlphaComponent(0.7), range: abs(m.range(at: 1)))
            }
            if let m = Self.listMarker.firstMatch(in: line, range: local) {
                storage.addAttributes([.foregroundColor: Palette.accent, .font: theme.font(weight: .semibold)], range: abs(m.range(at: 1)))
            }
            if let m = Self.taskBox.firstMatch(in: line, range: local) {
                storage.addAttributes([.foregroundColor: Palette.accent, .font: theme.codeFont], range: abs(m.range(at: 1)))
                let box = lineNS.substring(with: m.range(at: 1)).lowercased()
                if box == "[x]" {
                    let rest = NSRange(location: NSMaxRange(m.range), length: local.length - NSMaxRange(m.range))
                    storage.addAttributes([.foregroundColor: Palette.muted, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .strikethroughColor: Palette.marker], range: abs(rest))
                }
            }
            if Self.tablePipe.firstMatch(in: line, range: local) != nil {
                for (i, ch) in line.utf16.enumerated() where ch == 0x7C {  // "|"
                    storage.addAttribute(.foregroundColor, value: Palette.marker, range: NSRange(location: range.location + i, length: 1))
                }
                if line.allSatisfy({ "|-: \t".contains($0) }) {
                    storage.addAttribute(.foregroundColor, value: Palette.marker, range: range)
                }
            }
            if let m = Self.refLink.firstMatch(in: line, range: local) {
                storage.addAttribute(.foregroundColor, value: Palette.link, range: abs(m.range(at: 1)))
                storage.addAttribute(.foregroundColor, value: Palette.muted, range: abs(m.range(at: 2)))
            }
            _ = index
        }

        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: storage.string, range: full) { m, _, _ in
                guard let m else { return }
                if protected.intersects(integersIn: Range(m.range) ?? 0..<0) { return }
                body(m)
            }
        }

        each(Self.inlineCode) { m in
            storage.addAttributes([
                .font: theme.codeFont,
                .foregroundColor: Palette.inlineCode,
                .backgroundColor: Palette.codeBackground,
            ], range: m.range)
            storage.addAttribute(.foregroundColor, value: Palette.marker, range: m.range(at: 1))
            let close = NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length)
            storage.addAttribute(.foregroundColor, value: Palette.marker, range: close)
            protected.insert(integersIn: Range(m.range) ?? 0..<0)
        }
        each(Self.math) { m in
            storage.addAttributes([.font: theme.codeFont, .foregroundColor: Palette.codeBlock], range: m.range)
            protected.insert(integersIn: Range(m.range) ?? 0..<0)
        }
        each(Self.escape) { m in
            storage.addAttribute(.foregroundColor, value: Palette.marker, range: NSRange(location: m.range.location, length: 1))
        }
        each(Self.html) { m in
            storage.addAttribute(.foregroundColor, value: Palette.marker, range: m.range)
        }
        each(Self.bold) { m in
            addTrait(.boldFontMask, storage, m.range)
            dimDelimiters(storage, m, length: 2)
        }
        each(Self.italic) { m in
            addTrait(.italicFontMask, storage, m.range)
            dimDelimiters(storage, m, length: 1)
        }
        each(Self.strike) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Palette.muted], range: m.range(at: 2))
            dimDelimiters(storage, m, length: 2)
        }
        each(Self.highlight) { m in
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: m.range(at: 2))
            dimDelimiters(storage, m, length: 2)
        }
        each(Self.link) { m in
            storage.addAttribute(.foregroundColor, value: Palette.link, range: m.range(at: 2))
            for g in [1, 3, 5] { storage.addAttribute(.foregroundColor, value: Palette.marker, range: m.range(at: g)) }
            storage.addAttribute(.foregroundColor, value: Palette.muted, range: m.range(at: 4))
        }
        each(Self.autolink) { m in
            storage.addAttribute(.foregroundColor, value: Palette.link, range: m.range)
        }
        each(Self.footnote) { m in
            storage.addAttribute(.foregroundColor, value: Palette.link, range: m.range)
        }
    }

    private func addTrait(_ trait: NSFontTraitMask, _ storage: NSTextStorage, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            guard let font = value as? NSFont else { return }
            let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: sub)
        }
    }

    private func dimDelimiters(_ storage: NSTextStorage, _ m: NSTextCheckingResult, length: Int) {
        storage.addAttribute(.foregroundColor, value: Palette.marker, range: NSRange(location: m.range.location, length: length))
        storage.addAttribute(.foregroundColor, value: Palette.marker, range: NSRange(location: NSMaxRange(m.range) - length, length: length))
    }
}
