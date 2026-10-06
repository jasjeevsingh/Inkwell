import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }
    static var writableContentTypes: [UTType] { [.markdownText, .plainText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let utf16 = String(data: data, encoding: .utf16) {
            text = utf16
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct Heading: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    let line: Int
}

struct TextStats: Equatable {
    var words = 0
    var characters = 0
    var lines = 1

    var readingTime: String {
        let minutes = Int((Double(words) / 230).rounded(.up))
        return words == 0 ? "0 min" : "\(max(1, minutes)) min read"
    }
}

/// Line-oriented scanning shared by the outline, scroll sync, stats and task toggling.
enum MarkdownScan {
    private static let atxHeading = try! NSRegularExpression(pattern: #"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
    private static let fence = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#)
    static let task = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)*(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\]"#, options: [.anchorsMatchLines])

    /// UTF-16 offsets at which each line begins.
    static func lineStarts(of text: NSString) -> [Int] {
        var starts = [0]
        let length = text.length
        var i = 0
        while i < length {
            let c = text.character(at: i)
            if c == 10 { starts.append(i + 1) }
            else if c == 13 {
                if i + 1 < length, text.character(at: i + 1) == 10 { i += 1 }
                starts.append(i + 1)
            }
            i += 1
        }
        return starts
    }

    static func line(for location: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Iterates lines, reporting whether each sits inside a fenced code block or front matter.
    static func forEachLine(_ text: NSString, _ body: (_ index: Int, _ range: NSRange, _ line: String, _ inCode: Bool) -> Void) {
        var location = 0
        var index = 0
        var openFence: (char: Character, count: Int)?
        var inFrontMatter = false
        while location < text.length {
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: location, length: contentsEnd - location)
            let line = text.substring(with: range)

            if index == 0, line.trimmingCharacters(in: .whitespaces) == "---" {
                inFrontMatter = true
                body(index, range, line, true)
            } else if inFrontMatter {
                if line == "---" || line == "..." { inFrontMatter = false }
                body(index, range, line, true)
            } else if let m = fence.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let marker = (line as NSString).substring(with: m.range(at: 1))
                if let open = openFence {
                    if marker.first == open.char, marker.count >= open.count,
                       line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == open.char }) {
                        openFence = nil
                    }
                } else {
                    openFence = (marker.first!, marker.count)
                }
                body(index, range, line, true)
            } else {
                body(index, range, line, openFence != nil)
            }
            location = max(end, location + 1)
            index += 1
        }
    }

    static func headings(in text: NSString) -> [Heading] {
        var result: [Heading] = []
        forEachLine(text) { index, _, line, inCode in
            guard !inCode, line.contains("#") else { return }
            let ns = line as NSString
            guard let m = atxHeading.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return }
            let level = m.range(at: 1).length
            var title = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            title = title.replacingOccurrences(of: #"[*_`~]|\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            result.append(Heading(id: result.count, level: level, title: title.isEmpty ? "Untitled" : title, line: index))
        }
        return result
    }

    static func stats(of text: String) -> TextStats {
        var stats = TextStats()
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
                if scalar == "\n" { stats.lines += 1 }
            } else {
                stats.characters += 1
                if !inWord, CharacterSet.alphanumerics.contains(scalar) {
                    stats.words += 1
                    inWord = true
                } else if CharacterSet.alphanumerics.contains(scalar) {
                    inWord = true
                }
            }
        }
        return stats
    }

    /// Range of the `[ ]` / `[x]` marker for the nth task item, skipping fenced code.
    static func taskMarkerRange(_ n: Int, in text: NSString) -> NSRange? {
        var count = 0
        var found: NSRange?
        forEachLine(text) { _, range, line, inCode in
            guard found == nil, !inCode else { return }
            let ns = line as NSString
            if let m = task.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                if count == n { found = NSRange(location: range.location + m.range(at: 1).location, length: 1) }
                count += 1
            }
        }
        return found
    }
}
