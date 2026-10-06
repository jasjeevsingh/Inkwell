import SwiftUI
import AppKit
import CoreServices
import UniformTypeIdentifiers

struct TreeRow: Identifiable {
    let item: FileItem
    let depth: Int
    var id: URL { item.url }
}

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let isMarkdown: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// State handed from one window to the window it opens (workspace root, tab host).
@MainActor
enum WorkspaceHints {
    static var roots: [URL: URL] = [:]
    static var tabHosts: [URL: NSWindow] = [:]

    static var lastRoot: URL? {
        get { UserDefaults.standard.url(forKey: "lastWorkspace") }
        set { UserDefaults.standard.set(newValue, forKey: "lastWorkspace") }
    }
}

/// The folder tree shown in a window's sidebar, plus file operations on it.
@MainActor
final class WorkspaceModel: ObservableObject {
    enum Prompt: Identifiable {
        case newFile(URL), newFolder(URL), rename(URL)

        var id: String {
            switch self {
            case .newFile(let u): "file:" + u.path
            case .newFolder(let u): "folder:" + u.path
            case .rename(let u): "rename:" + u.path
            }
        }
        var title: String {
            switch self {
            case .newFile: "New Markdown File"
            case .newFolder: "New Folder"
            case .rename(let u): "Rename “\(u.lastPathComponent)”"
            }
        }
        var actionTitle: String {
            switch self {
            case .rename: "Rename"
            default: "Create"
            }
        }
        var message: String {
            switch self {
            case .newFile(let dir), .newFolder(let dir): "In “\(dir.lastPathComponent)”"
            case .rename: ""
            }
        }
    }

    @Published private(set) var root: URL?
    @Published private(set) var currentFile: URL?
    @Published var expanded: Set<URL> = []
    @Published var selection: URL?
    @Published private(set) var version = 0
    @Published var prompt: Prompt?
    @Published var promptText = ""
    @Published var pendingTrash: URL?
    @Published var errorMessage: String?
    @Published var showAllFiles = UserDefaults.standard.bool(forKey: "showAllFiles") {
        didSet {
            UserDefaults.standard.set(showAllFiles, forKey: "showAllFiles")
            invalidate()
        }
    }

    var hostWindow: () -> NSWindow? = { nil }
    private var cache: [URL: [FileItem]] = [:]
    private var watcher: DirectoryWatcher?

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Canonical form used for comparisons: symlinks resolved, no trailing slash.
    static func key(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().path, isDirectory: false)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: Root & current file

    /// Called when a window loads a document.
    func attach(file: URL?) {
        let file = file.map(Self.key)
        currentFile = file
        if let file, let hinted = WorkspaceHints.roots.removeValue(forKey: file) {
            setRoot(hinted)
        } else if let file {
            setRoot(file.deletingLastPathComponent())
        } else if let last = WorkspaceHints.lastRoot, Self.isDirectory(last) {
            setRoot(last)
        }
        selection = file
    }

    /// Called when the document's location changes (first save, rename, move).
    func fileMoved(to file: URL?) {
        let file = file.map(Self.key)
        guard file != currentFile else { return }
        currentFile = file
        if let file {
            if let root, isInside(file, root) {
                expandPath(to: file)
            } else {
                setRoot(file.deletingLastPathComponent())
            }
            selection = file
        }
        invalidate()
    }

    func setRoot(_ url: URL) {
        let url = Self.key(url)
        root = url
        cache.removeAll()
        watcher = DirectoryWatcher(path: url.path) { [weak self] in self?.invalidate() }
        if let currentFile { expandPath(to: currentFile) }
        WorkspaceHints.lastRoot = url
        version += 1
    }

    var ancestors: [URL] {
        guard var dir = root else { return [] }
        var result: [URL] = []
        while dir.path != "/" {
            dir = dir.deletingLastPathComponent()
            result.append(Self.key(dir))
        }
        return result
    }

    private func isInside(_ url: URL, _ dir: URL) -> Bool {
        url.path.hasPrefix(dir.path == "/" ? "/" : dir.path + "/")
    }

    private func expandPath(to file: URL) {
        guard let root else { return }
        var dir = file.deletingLastPathComponent()
        while isInside(dir, root) {
            expanded.insert(Self.key(dir))
            dir = dir.deletingLastPathComponent()
        }
    }

    func toggle(_ url: URL) {
        if expanded.contains(url) { expanded.remove(url) } else { expanded.insert(url) }
    }

    /// The tree flattened into the rows currently visible (expanded folders only).
    func visibleRows() -> [TreeRow] {
        guard let root else { return [] }
        var rows: [TreeRow] = []
        func walk(_ dir: URL, _ depth: Int) {
            for item in children(of: dir) {
                rows.append(TreeRow(item: item, depth: depth))
                if item.isDirectory, expanded.contains(item.url), depth < 40 { walk(item.url, depth + 1) }
            }
        }
        walk(root, 0)
        return rows
    }

    // MARK: Listing

    func children(of dir: URL) -> [FileItem] {
        if let cached = cache[dir] { return cached }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        var items: [FileItem] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            let markdown = !isDir && Self.isMarkdown(url)
            if !isDir, !markdown, !showAllFiles { continue }
            items.append(FileItem(url: Self.key(url), isDirectory: isDir, isMarkdown: markdown))
        }
        items.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        cache[dir] = items
        return items
    }

    func invalidate() {
        cache.removeAll()
        version += 1
    }

    // MARK: Opening

    func activate(_ url: URL) {
        if Self.isDirectory(url) {
            toggle(url)
        } else {
            open(url)
        }
    }

    func open(_ url: URL) {
        let url = Self.key(url)
        guard url != currentFile else { return }
        guard Self.isMarkdown(url) else {
            NSWorkspace.shared.open(url)
            return
        }
        if let root, isInside(url, root) { WorkspaceHints.roots[url] = root }
        if UserDefaults.standard.object(forKey: Prefs.openInTabs) as? Bool ?? true, let window = hostWindow() {
            WorkspaceHints.tabHosts[url] = window
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, alreadyOpen, error in
            MainActor.assumeIsolated {
                if alreadyOpen || error != nil {
                    WorkspaceHints.roots[url] = nil
                    WorkspaceHints.tabHosts[url] = nil
                }
                if let error { self?.errorMessage = error.localizedDescription }
                // Keep this window's highlight on its own document.
                self?.selection = self?.currentFile
            }
        }
    }

    // MARK: Creating & editing files

    /// Where new files go: the selected folder, the selected file's folder, the current document's folder, or the root.
    var targetDirectory: URL? {
        if let selection {
            return Self.isDirectory(selection) ? selection : selection.deletingLastPathComponent()
        }
        return currentFile?.deletingLastPathComponent() ?? root
    }

    func beginNewFile(in dir: URL? = nil) {
        guard let dir = dir ?? targetDirectory else {
            createFileWithPanel()
            return
        }
        promptText = uniqueName("Untitled.md", in: dir)
        prompt = .newFile(dir)
    }

    func beginNewFolder(in dir: URL? = nil) {
        guard let dir = dir ?? targetDirectory else { return }
        promptText = uniqueName("New Folder", in: dir)
        prompt = .newFolder(dir)
    }

    func beginRename(_ url: URL) {
        promptText = url.lastPathComponent
        prompt = .rename(url)
    }

    func commit(_ prompt: Prompt, name raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") || name.count > 1 else {
            errorMessage = "“\(raw)” isn’t a valid name."
            return
        }
        let fm = FileManager.default
        do {
            switch prompt {
            case .newFile(let dir):
                var fileName = name
                if (fileName as NSString).pathExtension.isEmpty { fileName += ".md" }
                let url = dir.appendingPathComponent(fileName)
                guard !fm.fileExists(atPath: url.path) else { throw nameTaken(fileName) }
                try Data().write(to: url, options: .withoutOverwriting)
                expanded.insert(Self.key(dir))
                invalidate()
                selection = Self.key(url)
                open(url)
            case .newFolder(let dir):
                let url = dir.appendingPathComponent(name)
                guard !fm.fileExists(atPath: url.path) else { throw nameTaken(name) }
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                expanded.insert(Self.key(dir))
                expanded.insert(Self.key(url))
                invalidate()
                selection = Self.key(url)
            case .rename(let url):
                let destination = url.deletingLastPathComponent().appendingPathComponent(name)
                guard destination.lastPathComponent != url.lastPathComponent else { return }
                guard !fm.fileExists(atPath: destination.path) ||
                      destination.path.lowercased() == url.path.lowercased() else { throw nameTaken(name) }
                try coordinatedMove(from: url, to: destination)
                if expanded.remove(url) != nil { expanded.insert(Self.key(destination)) }
                if selection == url { selection = Self.key(destination) }
                if currentFile == url { currentFile = Self.key(destination) }
                invalidate()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if selection == url { selection = nil }
            invalidate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// Lets the user pick a workspace folder.
    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        panel.directoryURL = root
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setRoot(url)
        }
        if let window = hostWindow() { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// Creates a new file anywhere using a Finder save panel, then opens it.
    func createFileWithPanel() {
        Self.createFileWithPanel(startingAt: targetDirectory ?? root, window: hostWindow()) { [weak self] url in
            guard let self else { return }
            if let root, self.isInside(url, root) { self.invalidate() }
            self.open(url)
        }
    }

    static func createFileWithPanel(startingAt directory: URL?, window: NSWindow?, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = "New Markdown File"
        panel.message = "Choose a name and a folder for the new file."
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Untitled.md"
        panel.allowedContentTypes = [.markdownText]
        panel.canCreateDirectories = true
        panel.directoryURL = directory ?? WorkspaceHints.lastRoot
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data().write(to: url)
                completion(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    // MARK: Helpers

    private func uniqueName(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 2...999 {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) { return candidate }
        }
        return name
    }

    private func nameTaken(_ name: String) -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "An item named “\(name)” already exists in this folder."])
    }

    /// Moves through NSFileCoordinator so open documents follow the file to its new location.
    private func coordinatedMove(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing, error: &coordinationError) { src, dst in
            do {
                coordinator.item(at: src, willMoveTo: dst)
                try FileManager.default.moveItem(at: src, to: dst)
                coordinator.item(at: src, didMoveTo: dst)
            } catch {
                moveError = error
            }
        }
        if let error = coordinationError ?? moveError { throw error }
    }
}

/// Watches a directory tree with FSEvents and reports (coalesced) changes on the main queue.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(path: String, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
