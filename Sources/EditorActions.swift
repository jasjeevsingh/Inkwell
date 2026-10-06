import AppKit

/// Markdown formatting commands that operate on a text view with full undo support.
@MainActor
enum EditorActions {
    nonisolated(unsafe) private static let listLine = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|\d+[.)])([ \t]+)(\[[ xX]\][ \t]+)?"#)
    nonisolated(unsafe) private static let quoteLine = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)+)"#)
    nonisolated(unsafe) private static let headingPrefix = try! NSRegularExpression(pattern: #"^ {0,3}#{1,6}[ \t]+"#)

    // MARK: Primitive

    static func replace(_ tv: NSTextView, _ range: NSRange, with string: String, select: NSRange? = nil, scroll: Bool = true) {
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: string)
        tv.didChangeText()
        if let select { tv.setSelectedRange(select) }
        if scroll { tv.scrollRangeToVisible(tv.selectedRange()) }
    }

    private static func ns(_ tv: NSTextView) -> NSString { tv.string as NSString }

    // MARK: Inline wrapping

    static func toggleWrap(_ tv: NSTextView, _ marker: String, placeholder: String = "text") {
        toggleWrap(tv, open: marker, close: marker, placeholder: placeholder)
    }

    static func toggleWrap(_ tv: NSTextView, open: String, close: String, placeholder: String) {
        let s = ns(tv)
        var sel = tv.selectedRange()
        let o = (open as NSString).length, c = (close as NSString).length

        // Expand an empty selection to the word under the cursor.
        if sel.length == 0 {
            let word = wordRange(in: s, at: sel.location)
            if word.length > 0 { sel = word }
        }
        let selected = s.substring(with: sel)

        // Already wrapped inside the selection → unwrap.
        if selected.hasPrefix(open), selected.hasSuffix(close), sel.length >= o + c {
            let inner = (selected as NSString).substring(with: NSRange(location: o, length: sel.length - o - c))
            replace(tv, sel, with: inner, select: NSRange(location: sel.location, length: (inner as NSString).length))
            return
        }
        // Wrapped just outside the selection → unwrap.
        if sel.location >= o, NSMaxRange(sel) + c <= s.length,
           s.substring(with: NSRange(location: sel.location - o, length: o)) == open,
           s.substring(with: NSRange(location: NSMaxRange(sel), length: c)) == close {
            let outer = NSRange(location: sel.location - o, length: sel.length + o + c)
            replace(tv, outer, with: selected, select: NSRange(location: outer.location, length: sel.length))
            return
        }
        if sel.length == 0 {
            replace(tv, sel, with: open + placeholder + close,
                    select: NSRange(location: sel.location + o, length: (placeholder as NSString).length))
        } else {
            replace(tv, sel, with: open + selected + close, select: NSRange(location: sel.location + o, length: sel.length))
        }
    }

    private static func wordRange(in s: NSString, at location: Int) -> NSRange {
        let letters = CharacterSet.alphanumerics
        func isWord(_ i: Int) -> Bool {
            guard i >= 0, i < s.length, let u = UnicodeScalar(s.character(at: i)) else { return false }
            return letters.contains(u)
        }
        var start = location, end = location
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    static func link(_ tv: NSTextView, image: Bool = false) {
        let sel = tv.selectedRange()
        let text = ns(tv).substring(with: sel)
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clipIsURL = clip.range(of: #"^(https?|mailto|file):\S+$"#, options: .regularExpression) != nil
        let label = text.isEmpty ? (image ? "alt text" : "link text") : text
        let url = clipIsURL ? clip : "https://"
        let insert = (image ? "!" : "") + "[\(label)](\(url))"
        let prefix = image ? 2 : 1
        let selectRange: NSRange
        if text.isEmpty {
            selectRange = NSRange(location: sel.location + prefix, length: (label as NSString).length)
        } else {
            let urlStart = sel.location + prefix + (label as NSString).length + 2
            selectRange = NSRange(location: urlStart, length: (url as NSString).length)
        }
        replace(tv, sel, with: insert, select: selectRange)
    }

    // MARK: Line operations

    /// Applies `transform` to every line touched by the selection.
    static func transformLines(_ tv: NSTextView, _ transform: ([String]) -> [String]) {
        let s = ns(tv)
        let sel = tv.selectedRange()
        var range = s.lineRange(for: sel)
        // Don't swallow the final newline.
        var trailingNewline = false
        if range.length > 0, s.character(at: NSMaxRange(range) - 1) == 10 {
            range.length -= 1
            trailingNewline = true
        }
        let lines = s.substring(with: range).components(separatedBy: "\n")
        let newText = transform(lines).joined(separator: "\n")
        _ = trailingNewline
        let newLength = (newText as NSString).length
        let selection = sel.length == 0
            ? NSRange(location: range.location + newLength - (range.length - (sel.location - range.location)).clamped(0, newLength), length: 0)
            : NSRange(location: range.location, length: newLength)
        replace(tv, range, with: newText, select: selection)
    }

    static func setHeading(_ tv: NSTextView, level: Int) {
        transformLines(tv) { lines in
            lines.map { line in
                let ns = line as NSString
                let existing = headingPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
                let body = existing.map { ns.substring(from: $0.range.length) } ?? line
                let currentLevel = existing.map { _ in line.trimmingCharacters(in: .whitespaces).prefix(while: { $0 == "#" }).count } ?? 0
                if level == 0 || currentLevel == level { return body }
                return String(repeating: "#", count: level) + " " + body
            }
        }
    }

    enum LinePrefix { case quote, bullet, numbered, task }

    static func toggleLinePrefix(_ tv: NSTextView, _ kind: LinePrefix) {
        transformLines(tv) { lines in
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            func has(_ line: String) -> Bool {
                let ns = line as NSString
                let r = NSRange(location: 0, length: ns.length)
                switch kind {
                case .quote: return quoteLine.firstMatch(in: line, range: r) != nil
                case .bullet, .numbered, .task:
                    guard let m = listLine.firstMatch(in: line, range: r) else { return false }
                    let marker = ns.substring(with: m.range(at: 2))
                    let isTask = m.range(at: 4).location != NSNotFound
                    switch kind {
                    case .task: return isTask
                    case .numbered: return marker.first!.isNumber && !isTask
                    default: return !marker.first!.isNumber && !isTask
                    }
                }
            }
            let removing = !nonEmpty.isEmpty && nonEmpty.allSatisfy(has)
            var n = 0
            return lines.map { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }
                let ns = line as NSString
                let r = NSRange(location: 0, length: ns.length)
                if kind == .quote {
                    if removing, let m = quoteLine.firstMatch(in: line, range: r) {
                        return ns.substring(from: m.range.length)
                    }
                    return "> " + line
                }
                // Strip any existing list marker, keeping indentation.
                var indent = ""
                var body = line
                if let m = listLine.firstMatch(in: line, range: r) {
                    indent = ns.substring(with: m.range(at: 1))
                    body = ns.substring(from: m.range.length)
                } else {
                    indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                    body = String(line.dropFirst(indent.count))
                }
                if removing { return indent + body }
                n += 1
                switch kind {
                case .bullet: return indent + "- " + body
                case .numbered: return indent + "\(n). " + body
                case .task: return indent + "- [ ] " + body
                case .quote: return line
                }
            }
        }
    }

    // MARK: Blocks

    static func codeBlock(_ tv: NSTextView) {
        let s = ns(tv)
        let sel = tv.selectedRange()
        if sel.length > 0 {
            let range = s.lineRange(for: sel)
            var body = s.substring(with: range)
            if !body.hasSuffix("\n") { body += "\n" }
            let text = "```\n" + body + "```\n"
            replace(tv, range, with: text, select: NSRange(location: range.location + 3, length: 0))
        } else {
            insertBlock(tv, "```\n\n```", cursorOffset: 3)
        }
    }

    static func table(_ tv: NSTextView) {
        insertBlock(tv, "| Column 1 | Column 2 | Column 3 |\n| -------- | -------- | -------- |\n| Cell     | Cell     | Cell     |", cursorOffset: 2, selectLength: 8)
    }

    static func horizontalRule(_ tv: NSTextView) {
        insertBlock(tv, "---", cursorOffset: 3)
    }

    /// Inserts a block on its own lines, separated from surrounding paragraphs by blank lines.
    static func insertBlock(_ tv: NSTextView, _ block: String, cursorOffset: Int, selectLength: Int = 0) {
        let s = ns(tv)
        let sel = tv.selectedRange()
        let before = sel.location > 0 ? s.substring(with: NSRange(location: max(0, sel.location - 2), length: min(2, sel.location))) : ""
        var prefix = ""
        if sel.location > 0 {
            if before.hasSuffix("\n\n") { prefix = "" }
            else if before.hasSuffix("\n") { prefix = "\n" }
            else { prefix = "\n\n" }
        }
        let afterIndex = NSMaxRange(sel)
        let after = afterIndex < s.length ? s.substring(with: NSRange(location: afterIndex, length: min(2, s.length - afterIndex))) : ""
        let suffix = after.hasPrefix("\n\n") ? "" : (after.hasPrefix("\n") ? "\n" : "\n\n")
        let text = prefix + block + suffix
        let caret = sel.location + (prefix as NSString).length + cursorOffset
        replace(tv, sel, with: text, select: NSRange(location: caret, length: selectLength))
    }

    // MARK: Smart editing

    /// Continues (or ends) a list / quote when Return is pressed. Returns false if not handled.
    static func continueList(_ tv: NSTextView) -> Bool {
        let s = ns(tv)
        let sel = tv.selectedRange()
        guard sel.length == 0 else { return false }
        let lineRange = s.lineRange(for: NSRange(location: sel.location, length: 0))
        var contentEnd = NSMaxRange(lineRange)
        while contentEnd > lineRange.location, [10, 13].contains(s.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let line = s.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        let ns = line as NSString
        let r = NSRange(location: 0, length: ns.length)
        guard sel.location - lineRange.location >= 0 else { return false }

        if let m = listLine.firstMatch(in: line, range: r) {
            guard sel.location >= lineRange.location + m.range.length else { return false }
            let rest = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                // Empty item: end the list.
                replace(tv, NSRange(location: lineRange.location, length: ns.length), with: "",
                        select: NSRange(location: lineRange.location, length: 0))
                return true
            }
            let indent = ns.substring(with: m.range(at: 1))
            var marker = ns.substring(with: m.range(at: 2))
            if let num = Int(marker.dropLast()) { marker = "\(num + 1)\(marker.last!)" }
            let spacing = ns.substring(with: m.range(at: 3))
            let task = m.range(at: 4).location != NSNotFound ? "[ ] " : ""
            let insert = "\n" + indent + marker + spacing + task
            replace(tv, sel, with: insert, select: NSRange(location: sel.location + (insert as NSString).length, length: 0))
            return true
        }
        if let m = quoteLine.firstMatch(in: line, range: r) {
            let rest = ns.substring(from: m.range.length).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                replace(tv, NSRange(location: lineRange.location, length: ns.length), with: "",
                        select: NSRange(location: lineRange.location, length: 0))
                return true
            }
            var prefix = ns.substring(with: m.range(at: 1))
            if !prefix.hasSuffix(" ") { prefix += " " }
            let insert = "\n" + prefix
            replace(tv, sel, with: insert, select: NSRange(location: sel.location + (insert as NSString).length, length: 0))
            return true
        }
        return false
    }

    /// Indents or outdents list items. Returns false if the selection isn't on list lines.
    static func indentList(_ tv: NSTextView, outdent: Bool) -> Bool {
        let s = ns(tv)
        let sel = tv.selectedRange()
        let first = s.lineRange(for: NSRange(location: sel.location, length: 0))
        let firstLine = s.substring(with: first)
        guard listLine.firstMatch(in: firstLine, range: NSRange(location: 0, length: (firstLine as NSString).length)) != nil else {
            return false
        }
        // Indentation step: the content offset of the closest previous list item, or 2 spaces.
        var step = 2
        if first.location > 0 {
            let prevRange = s.lineRange(for: NSRange(location: first.location - 1, length: 0))
            let prev = s.substring(with: prevRange)
            if let m = listLine.firstMatch(in: prev, range: NSRange(location: 0, length: (prev as NSString).length)) {
                let prevIndent = m.range(at: 1).length
                let curIndent = firstLine.prefix(while: { $0 == " " }).count
                let offset = m.range(at: 1).length + m.range(at: 2).length + m.range(at: 3).length
                if !outdent, offset > curIndent { step = offset - curIndent }
                if outdent, curIndent > prevIndent { step = curIndent - prevIndent }
            }
        }
        transformLines(tv) { lines in
            lines.map { line in
                if outdent {
                    let spaces = min(step, line.prefix(while: { $0 == " " }).count)
                    if spaces == 0, line.hasPrefix("\t") { return String(line.dropFirst()) }
                    return String(line.dropFirst(spaces))
                }
                return line.isEmpty ? line : String(repeating: " ", count: step) + line
            }
        }
        return true
    }

    static func toggleTask(_ tv: NSTextView, index: Int) {
        guard let r = MarkdownScan.taskMarkerRange(index, in: ns(tv)) else { return }
        let current = ns(tv).substring(with: r)
        let selection = tv.selectedRange()
        replace(tv, r, with: current == " " ? "x" : " ", select: selection, scroll: false)
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}
