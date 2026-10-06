import SwiftUI

struct DocumentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var model = WindowModel()
    @State private var loaded = false

    @AppStorage(Prefs.editorFont) private var editorFont = EditorFontStyle.mono.rawValue
    @AppStorage(Prefs.editorFontSize) private var editorFontSize = 15.0
    @AppStorage(Prefs.readableWidth) private var readableWidth = true
    @AppStorage(Prefs.spellCheck) private var spellCheck = false
    @AppStorage(Prefs.previewFont) private var previewFont = "sans"
    @AppStorage(Prefs.previewFontSize) private var previewFontSize = 16.0
    @AppStorage(Prefs.previewWidth) private var previewWidth = 780.0
    @AppStorage(Prefs.syncScroll) private var syncScroll = true
    @AppStorage(Prefs.defaultMode) private var defaultMode = ViewMode.split.rawValue
    @AppStorage(Prefs.zoom) private var zoom = 1.0
    @AppStorage(Prefs.splitRatio) private var splitRatio = 0.5
    @AppStorage(Prefs.showSidebar) private var showSidebar = true

    private var theme: EditorTheme {
        EditorTheme(style: EditorFontStyle(rawValue: editorFont) ?? .mono, size: CGFloat(editorFontSize * zoom))
    }

    private var previewOptions: PreviewOptions {
        PreviewOptions(font: previewFont, fontSize: previewFontSize * zoom, width: previewWidth)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columns) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 250, max: 380)
        } detail: {
            VStack(spacing: 0) {
                SplitPane(mode: model.mode, ratio: $splitRatio) {
                    EditorView(text: $document.text, model: model, theme: theme,
                               readableWidth: readableWidth, spellCheck: spellCheck)
                } right: {
                    PreviewView(controller: model.preview)
                }
                StatusBar(stats: model.stats, cursor: model.cursor, mode: model.mode)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .toolbar { DocumentToolbar(model: model) }
        .focusedSceneObject(model)
        .modifier(WorkspaceDialogs(workspace: model.workspace))
        .frame(minWidth: 620, minHeight: 380)
        .onAppear {
            model.syncScroll = syncScroll
            model.preview.setOptions(previewOptions)
            let binding = $document
            model.onExternalChange = { newText in binding.wrappedValue.text = newText }
            if !loaded {
                loaded = true
                if showSidebar { model.columns = .all }
                model.load(text: document.text, url: fileURL, mode: ViewMode(rawValue: defaultMode) ?? .split)
            }
        }
        .onChange(of: fileURL) { _, url in model.fileURL = url }
        .onChange(of: previewOptions) { _, options in model.preview.setOptions(options) }
        .onChange(of: syncScroll) { _, value in model.syncScroll = value }
    }
}

// MARK: - Split pane

/// Editor | preview layout that keeps both views alive while switching modes.
struct SplitPane<Left: View, Right: View>: View {
    let mode: ViewMode
    @Binding var ratio: Double
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let minPane: CGFloat = 260
            let leftWidth: CGFloat = {
                switch mode {
                case .editor: return total
                case .preview: return 0
                case .split: return min(max(minPane, total * ratio), max(minPane, total - minPane))
                }
            }()
            let dividerWidth: CGFloat = mode == .split ? 1 : 0
            let rightWidth = max(0, total - leftWidth - dividerWidth)

            HStack(spacing: 0) {
                left
                    .frame(width: max(leftWidth, mode == .preview ? 420 : 0))
                    .frame(width: leftWidth, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(mode != .preview)
                    .accessibilityHidden(mode == .preview)

                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: dividerWidth)
                    .overlay {
                        if mode == .split {
                            Color.clear
                                .frame(width: 9)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() } else if !dragging { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                                        .onChanged { value in
                                            dragging = true
                                            ratio = Double(min(max(value.location.x / total, 0.2), 0.8))
                                        }
                                        .onEnded { _ in
                                            dragging = false
                                            NSCursor.pop()
                                        }
                                )
                                .onTapGesture(count: 2) { ratio = 0.5 }
                        }
                    }

                right
                    .frame(width: max(rightWidth, mode == .editor ? 420 : 0))
                    .frame(width: rightWidth, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(mode != .editor)
                    .accessibilityHidden(mode == .editor)
            }
            .coordinateSpace(name: "split")
        }
    }
}

// MARK: - Outline

struct OutlineView: View {
    let headings: [Heading]
    let onSelect: (Heading) -> Void

    var body: some View {
        List {
            Section {
                if headings.isEmpty {
                    Text("Headings appear here")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
                ForEach(headings) { heading in
                    Button {
                        onSelect(heading)
                    } label: {
                        Text(heading.title)
                            .font(heading.level == 1 ? .body.weight(.semibold) : .body)
                            .foregroundStyle(heading.level <= 2 ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, CGFloat(max(0, heading.level - 1)) * 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(heading.title)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    let stats: TextStats
    let cursor: CursorPosition
    let mode: ViewMode

    var body: some View {
        HStack(spacing: 0) {
            Text("\(stats.words.formatted()) \(stats.words == 1 ? "word" : "words")")
            dot
            Text("\(stats.characters.formatted()) characters")
            dot
            Text(stats.readingTime)
            Spacer(minLength: 12)
            if mode != .preview {
                Text("Ln \(cursor.line), Col \(cursor.column)")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var dot: some View {
        Text("·").padding(.horizontal, 7).foregroundStyle(.tertiary)
    }
}

// MARK: - Toolbar

struct DocumentToolbar: ToolbarContent {
    @ObservedObject var model: WindowModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Editor ⌘1 · Split ⌘2 · Preview ⌘3")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            formattingControls.disabled(model.mode == .preview)
        }
    }

    @ViewBuilder
    private var formattingControls: some View {
            Menu {
                Button("Paragraph") { model.format { EditorActions.setHeading($0, level: 0) } }
                Divider()
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { model.format { EditorActions.setHeading($0, level: level) } }
                }
            } label: {
                Label("Heading", systemImage: "textformat.size")
            }
            .help("Heading")

            Button { model.format { EditorActions.toggleWrap($0, "**") } } label: { Label("Bold", systemImage: "bold") }
                .help("Bold ⌘B")
            Button { model.format { EditorActions.toggleWrap($0, "*") } } label: { Label("Italic", systemImage: "italic") }
                .help("Italic ⌘I")
            Button { model.format { EditorActions.toggleWrap($0, "~~") } } label: { Label("Strikethrough", systemImage: "strikethrough") }
                .help("Strikethrough ⇧⌘X")
            Button { model.format { EditorActions.toggleWrap($0, "`", placeholder: "code") } } label: {
                Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Inline code ⌃`")
            Button { model.format { EditorActions.link($0) } } label: { Label("Link", systemImage: "link") }
                .help("Link ⌘K")

            Menu {
                Button("Bulleted List", systemImage: "list.bullet") { model.format { EditorActions.toggleLinePrefix($0, .bullet) } }
                Button("Numbered List", systemImage: "list.number") { model.format { EditorActions.toggleLinePrefix($0, .numbered) } }
                Button("Task List", systemImage: "checklist") { model.format { EditorActions.toggleLinePrefix($0, .task) } }
                Button("Quote", systemImage: "text.quote") { model.format { EditorActions.toggleLinePrefix($0, .quote) } }
            } label: {
                Label("Lists", systemImage: "list.bullet")
            }
            .help("Lists and quotes")

            Menu {
                Button("Code Block", systemImage: "curlybraces") { model.format(EditorActions.codeBlock) }
                Button("Table", systemImage: "tablecells") { model.format(EditorActions.table) }
                Button("Image", systemImage: "photo") { model.format { EditorActions.link($0, image: true) } }
                Button("Horizontal Rule", systemImage: "minus") { model.format(EditorActions.horizontalRule) }
            } label: {
                Label("Insert", systemImage: "plus")
            }
            .help("Insert")
    }
}
