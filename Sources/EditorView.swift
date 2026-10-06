import SwiftUI
import AppKit

final class MarkdownTextView: NSTextView {
    var documentDirectory: (() -> URL?)?

    private static let pairs: [String: String] = ["*": "*", "_": "_", "`": "`", "~": "~", "\"": "\"", "(": ")", "[": "]"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "bmp", "tif", "tiff", "avif"]

    override func insertNewline(_ sender: Any?) {
        if EditorActions.continueList(self) { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if EditorActions.indentList(self, outdent: false) { return }
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        if EditorActions.indentList(self, outdent: true) { return }
        super.insertBacktab(sender)
    }

    /// Typing a delimiter with text selected wraps the selection instead of replacing it.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let s = string as? String, let close = Self.pairs[s], !hasMarkedText(),
           replacementRange.location == NSNotFound, selectedRange().length > 0 {
            let sel = selectedRange()
            let inner = (self.string as NSString).substring(with: sel)
            EditorActions.replace(self, sel, with: s + inner + close, select: NSRange(location: sel.location + 1, length: sel.length))
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Pasting a URL over selected text makes a link.
    override func paste(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0,
           let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
            let text = (string as NSString).substring(with: sel)
            if !text.contains("\n") {
                let link = "[\(text)](\(clip))"
                EditorActions.replace(self, sel, with: link, select: NSRange(location: sel.location + (link as NSString).length, length: 0))
                return
            }
        }
        pasteAsPlainText(sender)
    }

    /// Dropping files inserts Markdown links / images with paths relative to the document.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        let base = documentDirectory?()
        let text = urls.map { url -> String in
            let path = base.map { Self.relativePath(from: $0, to: url) } ?? url.path
            let encoded = path.replacingOccurrences(of: " ", with: "%20")
            if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                return "![\(url.deletingPathExtension().lastPathComponent)](\(encoded))"
            }
            return "[\(url.lastPathComponent)](\(encoded))"
        }.joined(separator: "\n")
        EditorActions.replace(self, NSRange(location: index, length: 0), with: text,
                              select: NSRange(location: index + (text as NSString).length, length: 0))
        window?.makeFirstResponder(self)
        return true
    }

    static func relativePath(from base: URL, to target: URL) -> String {
        let b = base.standardizedFileURL.pathComponents
        let t = target.standardizedFileURL.pathComponents
        var i = 0
        while i < b.count, i < t.count, b[i] == t[i] { i += 1 }
        if i <= 1 { return target.path }
        return (Array(repeating: "..", count: b.count - i) + t[i...]).joined(separator: "/")
    }
}

/// Bridges a window's model to its text view.
@MainActor
final class EditorController {
    weak var textView: MarkdownTextView?

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    func scrollToLine(_ line: Int) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer,
              let scroll = tv.enclosingScrollView else { return }
        let starts = MarkdownScan.lineStarts(of: tv.string as NSString)
        guard line < starts.count else { return }
        let location = starts[line]
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: min((tv.string as NSString).length, location + 1)))
        let rect: NSRect = glyphRange.location < lm.numberOfGlyphs
            ? lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            : lm.extraLineFragmentRect
        _ = tc
        let maxY = max(0, tv.frame.height - scroll.contentSize.height)
        let y = min(maxY, max(0, rect.minY + tv.textContainerOrigin.y - 16))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        tv.setSelectedRange(NSRange(location: location, length: 0))
    }
}

struct EditorView: NSViewRepresentable {
    @Binding var text: String
    let model: WindowModel
    let theme: EditorTheme
    let readableWidth: Bool
    let spellCheck: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        // TextKit 1 stack: predictable layout queries for scroll sync and fast restyling.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = MarkdownTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = spellCheck
        tv.smartInsertDeleteEnabled = false
        tv.allowsDocumentBackgroundColorChange = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.insertionPointColor = .controlAccentColor
        tv.textContainerInset = NSSize(width: 32, height: 28)
        tv.typingAttributes = theme.baseAttributes
        tv.string = text
        tv.delegate = context.coordinator

        scroll.documentView = tv
        context.coordinator.attach(tv, scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        var restyle = false
        if c.theme != theme {
            c.theme = theme
            tv.typingAttributes = theme.baseAttributes
            restyle = true
        }
        if tv.string != text {
            // Changed outside the editor (file reloaded from disk, revert, etc.)
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
            restyle = true
            let model = self.model, newText = text
            DispatchQueue.main.async { model.textDidChange(newText) }
        }
        if tv.isContinuousSpellCheckingEnabled != spellCheck { tv.isContinuousSpellCheckingEnabled = spellCheck }
        if restyle { c.highlight() }
        if c.readableWidth != readableWidth || restyle {
            c.readableWidth = readableWidth
            c.updateInsets()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorView
        weak var textView: MarkdownTextView?
        weak var scrollView: NSScrollView?
        var theme: EditorTheme
        var readableWidth: Bool

        init(_ parent: EditorView) {
            self.parent = parent
            self.theme = parent.theme
            self.readableWidth = parent.readableWidth
        }

        func attach(_ tv: MarkdownTextView, _ scroll: NSScrollView) {
            textView = tv
            scrollView = scroll
            let model = parent.model
            model.editor.textView = tv
            tv.documentDirectory = { [weak model] in model?.fileURL?.deletingLastPathComponent() }
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(didScroll),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            scroll.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(frameChanged),
                                                   name: NSView.frameDidChangeNotification, object: scroll)
            highlight()
            updateInsets()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            highlight()
            let s = tv.string
            parent.text = s
            parent.model.textDidChange(s)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.model.selectionChanged(tv.selectedRange().location)
        }

        func highlight() {
            guard let storage = textView?.textStorage else { return }
            MarkdownHighlighter(theme: theme).apply(to: storage)
        }

        @objc func frameChanged() { updateInsets() }

        func updateInsets() {
            guard let tv = textView, let scroll = scrollView else { return }
            let width = scroll.contentSize.width
            let maxText: CGFloat = readableWidth ? max(560, theme.size * 46) : .greatestFiniteMagnitude
            let horizontal = max(28, ((width - maxText) / 2).rounded())
            let inset = NSSize(width: horizontal, height: 30)
            if tv.textContainerInset != inset { tv.textContainerInset = inset }
        }

        @objc func didScroll() {
            guard let tv = textView, let scroll = scrollView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            let visible = scroll.contentView.bounds
            let length = (tv.string as NSString).length
            let atBottom = visible.maxY >= tv.frame.height - 2
            guard length > 0 else { return }
            let point = NSPoint(x: 4, y: max(0, visible.minY - tv.textContainerOrigin.y))
            let glyph = lm.glyphIndex(for: point, in: tc)
            let charIndex = min(lm.characterIndexForGlyph(at: glyph), length - 1)
            let ns = tv.string as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: charIndex, length: 0))
            let glyphs = lm.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let fraction = rect.height > 0
                ? min(1, max(0, (visible.minY - tv.textContainerOrigin.y - rect.minY) / rect.height))
                : 0
            parent.model.editorDidScroll(charIndex: paragraph.location, fraction: fraction, atBottom: atBottom,
                                         atTop: visible.minY <= 1)
        }
    }
}
