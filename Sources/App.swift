import SwiftUI
import UniformTypeIdentifiers

@main
struct InkwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { InkwellCommands() }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply(UserDefaults.standard.string(forKey: Prefs.appearance) ?? "system")
    }
}

enum Prefs {
    static let editorFont = "editorFont"
    static let editorFontSize = "editorFontSize"
    static let readableWidth = "readableWidth"
    static let spellCheck = "spellCheck"
    static let previewFont = "previewFont"
    static let previewFontSize = "previewFontSize"
    static let previewWidth = "previewWidth"
    static let syncScroll = "syncScroll"
    static let defaultMode = "defaultMode"
    static let appearance = "appearance"
    static let zoom = "zoom"
    static let splitRatio = "splitRatio"
    static let showSidebar = "showSidebar"
    static let openInTabs = "openInTabs"
}

enum Appearance {
    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

enum DefaultApp {
    static var markdownTypes: [UTType] {
        var seen = Set<String>()
        return ([UTType.markdownText] + ["md", "markdown", "mdown", "mkd", "mkdn"].compactMap { UTType(filenameExtension: $0) })
            .filter { seen.insert($0.identifier).inserted }
    }

    static var isDefault: Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: .markdownText) else { return false }
        return app.standardizedFileURL.resolvingSymlinksInPath() == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    @MainActor
    static func makeDefault() async -> Bool {
        var ok = true
        for type in markdownTypes {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
            } catch {
                ok = false
            }
        }
        return ok
    }
}

// MARK: - Menus

struct InkwellCommands: Commands {
    @FocusedObject private var model: WindowModel?
    @AppStorage(Prefs.zoom) private var zoom = 1.0
    @AppStorage(Prefs.syncScroll) private var syncScroll = true

    private var editing: Bool { model != nil && model?.mode != .preview }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New File in Folder…") { model?.workspace.beginNewFile() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("New File in Another Location…") {
                if let model {
                    model.workspace.createFileWithPanel()
                } else {
                    WorkspaceModel.createFileWithPanel(startingAt: nil, window: nil) { url in
                        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                    }
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .option, .shift])
            Button("New Folder…") { model?.workspace.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model?.workspace.root == nil)
            Divider()
            Button("Open Folder…") {
                model?.showSidebar(.files)
                model?.workspace.chooseRoot()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(model == nil)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export as HTML…") { model?.exportHTML() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Export as PDF…") { model?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model == nil)
            Button("Copy as HTML") { model?.copyHTML() }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(model == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { model?.printDocument() }
                .keyboardShortcut("p")
                .disabled(model == nil)
        }

        CommandGroup(before: .sidebar) {
            Button("Editor Only") { model?.mode = .editor }
                .keyboardShortcut("1")
                .disabled(model == nil)
            Button("Editor and Preview") { model?.mode = .split }
                .keyboardShortcut("2")
                .disabled(model == nil)
            Button("Preview Only") { model?.mode = .preview }
                .keyboardShortcut("3")
                .disabled(model == nil)
            Toggle("Sync Scrolling", isOn: $syncScroll)
            Divider()
            Button("Show Files") { model?.showSidebar(.files) }
                .keyboardShortcut("1", modifiers: [.command, .control])
                .disabled(model == nil)
            Button("Show Outline") { model?.showSidebar(.outline) }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .disabled(model == nil)
            Divider()
            Button("Actual Size") { zoom = 1.0 }
                .keyboardShortcut("0")
            Button("Zoom In") { zoom = min(2.0, zoom + 0.1) }
                .keyboardShortcut("=")
            Button("Zoom Out") { zoom = max(0.6, zoom - 0.1) }
                .keyboardShortcut("-")
            Divider()
        }

        CommandMenu("Format") {
            Button("Bold") { model?.format { EditorActions.toggleWrap($0, "**") } }
                .keyboardShortcut("b")
            Button("Italic") { model?.format { EditorActions.toggleWrap($0, "*") } }
                .keyboardShortcut("i")
            Button("Strikethrough") { model?.format { EditorActions.toggleWrap($0, "~~") } }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Highlight") { model?.format { EditorActions.toggleWrap($0, "==") } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Inline Code") { model?.format { EditorActions.toggleWrap($0, "`", placeholder: "code") } }
                .keyboardShortcut("`", modifiers: .control)
            Button("Link") { model?.format { EditorActions.link($0) } }
                .keyboardShortcut("k")
            Button("Image") { model?.format { EditorActions.link($0, image: true) } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Paragraph") { model?.format { EditorActions.setHeading($0, level: 0) } }
                .keyboardShortcut("0", modifiers: [.command, .option])
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { model?.format { EditorActions.setHeading($0, level: level) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .option])
            }
            Divider()
            Button("Bulleted List") { model?.format { EditorActions.toggleLinePrefix($0, .bullet) } }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered List") { model?.format { EditorActions.toggleLinePrefix($0, .numbered) } }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Task List") { model?.format { EditorActions.toggleLinePrefix($0, .task) } }
                .keyboardShortcut("9", modifiers: [.command, .shift])
            Button("Quote") { model?.format { EditorActions.toggleLinePrefix($0, .quote) } }
                .keyboardShortcut("'", modifiers: [.command, .shift])
            Divider()
            Button("Code Block") { model?.format(EditorActions.codeBlock) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Table") { model?.format(EditorActions.table) }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Horizontal Rule") { model?.format(EditorActions.horizontalRule) }
                .keyboardShortcut("-", modifiers: [.command, .option])
        }
    }
}
