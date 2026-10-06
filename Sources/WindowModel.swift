import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ViewMode: String, CaseIterable, Identifiable {
    case editor, split, preview
    var id: String { rawValue }
    var label: String {
        switch self {
        case .editor: "Editor"
        case .split: "Split"
        case .preview: "Preview"
        }
    }
    var icon: String {
        switch self {
        case .editor: "square.and.pencil"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }
}

struct CursorPosition: Equatable {
    var line = 1
    var column = 1
}

/// Per-window state: the text, derived info (outline, stats) and the editor/preview controllers.
@MainActor
final class WindowModel: ObservableObject {
    @Published var mode: ViewMode = .split {
        didSet { if oldValue != mode { modeChanged() } }
    }
    @Published private(set) var stats = TextStats()
    @Published private(set) var headings: [Heading] = []
    @Published private(set) var cursor = CursorPosition()
    @Published var columns: NavigationSplitViewVisibility = .detailOnly
    @Published var sidebarTab: SidebarTab = .files

    let editor = EditorController()
    let preview = PreviewController()
    let workspace = WorkspaceModel()

    var fileURL: URL? {
        didSet {
            guard oldValue != fileURL else { return }
            flush()
            if loaded { workspace.fileMoved(to: fileURL) }
        }
    }
    private var loaded = false
    var syncScroll = true

    private(set) var text = ""
    private var lineStarts: [Int] = [0]
    private var pending: DispatchWorkItem?

    /// Called when the file changes on disk while there are no unsaved edits.
    var onExternalChange: ((String) -> Void)?
    private var diskText: String?
    private var diskDate: Date?
    nonisolated(unsafe) private var watchTimer: Timer?

    init() {
        preview.model = self
        workspace.hostWindow = { [weak self] in self?.window }
    }

    deinit {
        watchTimer?.invalidate()
    }

    var baseURL: String {
        fileURL?.deletingLastPathComponent().absoluteString ?? ""
    }

    var window: NSWindow? {
        editor.textView?.window ?? preview.webView.window
    }

    var documentName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    func load(text: String, url: URL?, mode: ViewMode) {
        self.text = text
        self.fileURL = url
        self.mode = mode
        lineStarts = MarkdownScan.lineStarts(of: text as NSString)
        flush()
        modeChanged()
        startWatching()
        workspace.attach(file: url)
        loaded = true
        joinTabGroupIfRequested(attempts: 20)
    }

    func showSidebar(_ tab: SidebarTab) {
        sidebarTab = tab
        columns = .all
    }

    /// Windows opened from another window's file tree join it as a tab.
    private func joinTabGroupIfRequested(attempts: Int) {
        guard let url = fileURL.map(WorkspaceModel.key), WorkspaceHints.tabHosts[url] != nil else { return }
        guard let window else {
            if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.joinTabGroupIfRequested(attempts: attempts - 1)
                }
            } else {
                WorkspaceHints.tabHosts[url] = nil
            }
            return
        }
        guard let host = WorkspaceHints.tabHosts.removeValue(forKey: url), host !== window, host.isVisible else { return }
        if host.tabbedWindows?.contains(window) != true {
            host.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: External changes

    private func startWatching() {
        watchTimer?.invalidate()
        diskText = text
        diskDate = fileURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func checkDisk() {
        guard let url = fileURL,
              let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date != diskDate else { return }
        diskDate = date
        guard let data = try? Data(contentsOf: url),
              let newText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return }
        defer { diskText = newText }
        // Our own save, or nothing changed.
        guard newText != text else { return }
        // Only reload if there are no unsaved local edits; otherwise leave the conflict to the save flow.
        if text == diskText { onExternalChange?(newText) }
    }

    func textDidChange(_ newText: String) {
        text = newText
        lineStarts = MarkdownScan.lineStarts(of: newText as NSString)
        if let tv = editor.textView { selectionChanged(tv.selectedRange().location) }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    private func flush() {
        pending?.cancel()
        pending = nil
        let ns = text as NSString
        let newHeadings = MarkdownScan.headings(in: ns)
        if newHeadings != headings { headings = newHeadings }
        let newStats = MarkdownScan.stats(of: text)
        if newStats != stats { stats = newStats }
        preview.render(text, base: baseURL)
    }

    func selectionChanged(_ location: Int) {
        let line = MarkdownScan.line(for: location, in: lineStarts)
        let position = CursorPosition(line: line + 1, column: max(1, location - lineStarts[line] + 1))
        if position != cursor { cursor = position }
    }

    // MARK: Scrolling

    func editorDidScroll(charIndex: Int, fraction: Double, atBottom: Bool, atTop: Bool) {
        guard syncScroll, mode == .split else { return }
        let line = Double(MarkdownScan.line(for: charIndex, in: lineStarts)) + fraction
        preview.syncScroll(topLine: atTop ? 0 : line, totalLines: lineStarts.count,
                           headingLines: headings.map(\.line), atBottom: atBottom && !atTop)
    }

    func jump(to heading: Heading) {
        switch mode {
        case .preview:
            preview.scrollToHeading(index: heading.id, line: heading.line, total: lineStarts.count)
        case .editor, .split:
            editor.scrollToLine(heading.line)
            editor.focus()
        }
    }

    private func modeChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.mode == .preview {
                self.window?.makeFirstResponder(self.preview.webView)
            } else {
                self.editor.focus()
            }
        }
    }

    // MARK: Editing

    func format(_ action: (NSTextView) -> Void) {
        guard mode != .preview, let tv = editor.textView else { return }
        tv.window?.makeFirstResponder(tv)
        action(tv)
    }

    func toggleTask(index: Int) {
        guard let tv = editor.textView else { return }
        EditorActions.toggleTask(tv, index: index)
    }

    // MARK: Export

    func copyHTML() {
        Task {
            guard let html = await preview.renderedHTML() else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(html, forType: .html)
            pb.setString(html, forType: .string)
        }
    }

    func exportHTML() {
        Task {
            guard let body = await preview.renderedHTML() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue = documentName + ".html"
            panel.canCreateDirectories = true
            panel.directoryURL = fileURL?.deletingLastPathComponent()
            let response = await present(panel)
            guard response == .OK, let url = panel.url else { return }
            let html = PreviewController.standaloneHTML(body: body, title: documentName, forPrint: false)
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func exportPDF() {
        Task {
            guard let body = await preview.renderedHTML() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = documentName + ".pdf"
            panel.canCreateDirectories = true
            panel.directoryURL = fileURL?.deletingLastPathComponent()
            let response = await present(panel)
            guard response == .OK, let url = panel.url else { return }
            preview.print(body: body, title: documentName, window: window, saveTo: url)
        }
    }

    func printDocument() {
        Task {
            guard let body = await preview.renderedHTML() else { return }
            preview.print(body: body, title: documentName, window: window, saveTo: nil)
        }
    }

    private func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        if let window {
            return await panel.beginSheetModal(for: window)
        }
        return panel.runModal()
    }
}
